import AVFoundation
import AVKit
import Observation
import UIKit

nonisolated struct Chapter: Identifiable, Hashable { var id: Double { time }; var time: Double; var title: String }

nonisolated struct CaptionCue: Hashable { var start: Double; var end: Double; var text: String }

/// One audio rendition of an HLS video: the original or a dubbed language.
nonisolated struct AudioTrackOption: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var language: String?
    var isOriginal: Bool
    var isDubbed: Bool
    var rawName: String = ""
}

nonisolated struct SponsorSegment: Hashable { var start: Double; var end: Double; var category: String }

enum VideoQualityCap: String, CaseIterable, Identifiable {
    case auto, p2160, p1440, p1080, p720, p480, p360
    var id: String { rawValue }
    var title: String { self == .auto ? String(localized: "Auto") : String(rawValue.dropFirst()) + "p" }
    var size: CGSize {
        switch self {
        case .auto: .zero
        case .p2160: CGSize(width: 3840, height: 2160)
        case .p1440: CGSize(width: 2560, height: 1440)
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p720: CGSize(width: 1280, height: 720)
        case .p480: CGSize(width: 854, height: 480)
        case .p360: CGSize(width: 640, height: 360)
        }
    }
}

/// The video surface: HLS playback through AVPlayer (adaptive up to 2160p60,
/// AirPlay and Picture in Picture for free), video queue with autoplay,
/// chapters, SponsorBlock, resume positions and watch history.
@MainActor
@Observable
final class VideoPlayerModel {
    static let shared = VideoPlayerModel()

    var current: Video?
    var details: WatchDetails?
    var isPresented = false
    var isLoading = false
    var errorMessage: String?
    var isPlaying = false
    var chapters: [Chapter] = []
    var segments: [SponsorSegment] = []
    var skippedNotice: String?
    var queue: [Video] = []
    var audioTracks: [AudioTrackOption] = []
    var selectedAudio: AudioTrackOption?
    var captionTracks: [CaptionTrack] = []
    var selectedCaption: CaptionTrack? { didSet { Task { await loadCaptions() } } }
    var currentCaption: String?
    @ObservationIgnored private var cues: [CaptionCue] = []
    @ObservationIgnored private var audibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored private var audibleOptions: [String: AVMediaSelectionOption] = [:]
    var quality: VideoQualityCap = VideoQualityCap(rawValue: UserDefaults.standard.string(forKey: "videoQuality") ?? "auto") ?? .auto {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "videoQuality")
            player.currentItem?.preferredMaximumResolution = quality.size
        }
    }

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    var library: LibraryStore { .shared }

    init() {
        player.allowsExternalPlayback = true
        // Koda chooses the audio rendition itself: the original track unless the viewer picks a dub,
        // rather than AVPlayer's automatic match to the device language.
        player.appliesMediaSelectionCriteriaAutomatically = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        rateObservation = player.observe(\.timeControlStatus) { @Sendable [weak self] p, _ in
            Task { @MainActor in self?.isPlaying = p.timeControlStatus != .paused }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            // Compare identities, so the non-Sendable notification never crosses into the main actor.
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let ended, let current = self.player.currentItem, ended == ObjectIdentifier(current) else { return }
                self.ended()
            }
        }
    }

    func open(_ video: Video, queue: [Video] = []) {
        MusicPlayer.shared.pause()
        if current?.id == video.id { isPresented = true; return }
        saveProgress()
        current = video
        details = nil
        chapters = []
        segments = []
        errorMessage = nil
        audioTracks = []
        selectedAudio = nil
        captionTracks = []
        cues = []
        currentCaption = nil
        if !queue.isEmpty { self.queue = queue.filter { $0.id != video.id } }
        isPresented = true
        library.recordWatch(video)
        load(video)
    }

    func close() {
        saveProgress()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        details = nil
        isPresented = false
    }

    private func load(_ video: Video) {
        loadTask?.cancel()
        isLoading = true
        player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        loadTask = Task {
            async let detailsTask = try? VideoAPI.watch(video.id)
            async let segmentsTask = Self.sponsorSegments(video.id)
            do {
                let info = try await InnerTube.shared.player(videoId: video.id)
                guard !Task.isCancelled, current?.id == video.id else { return }
                guard let url = info.hlsURL else { throw InnerTubeError.noStream }
                let item = AVPlayerItem(asset: AVURLAsset(url: url))
                item.preferredMaximumResolution = quality.size
                item.externalMetadata = Self.metadata(title: info.title, artist: info.author)
                player.replaceCurrentItem(with: item)
                let preferredLanguage = Locale.current.language.languageCode?.identifier ?? "en"
                captionTracks = info.captions.sorted { a, b in
                    let ra = (a.language.hasPrefix(preferredLanguage) ? 0 : 2) + (a.isAutoGenerated ? 1 : 0)
                    let rb = (b.language.hasPrefix(preferredLanguage) ? 0 : 2) + (b.isAutoGenerated ? 1 : 0)
                    return ra < rb
                }
                // Subtitles start off unless the viewer asked for them to turn on by themselves.
                if UserDefaults.standard.bool(forKey: "autoSubtitles"),
                   let preferred = UserDefaults.standard.string(forKey: "captionLanguage"),
                   let track = info.captions.first(where: { $0.language == preferred && !$0.isAutoGenerated })
                    ?? info.captions.first(where: { $0.language == preferred }) {
                    selectedCaption = track
                } else {
                    selectedCaption = nil
                }
                await loadAudioTracks(item, originalLanguage: info.originalAudioLanguage)
                let resume = library.data.videoHistory.first { $0.video.id == video.id }?.position ?? 0
                if resume > 10, info.duration - resume > 20 {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                guard !Task.isCancelled, current?.id == video.id else { return }
                player.play()
                isLoading = false
                errorMessage = nil
            } catch {
                // A superseded load fails with a cancellation error: it belongs to the old video.
                guard !Task.isCancelled, current?.id == video.id else { return }
                isLoading = false
                if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                    errorMessage = error.localizedDescription
                }
            }
            let d = await detailsTask
            let s = await segmentsTask
            guard current?.id == video.id else { return }
            if let d {
                details = d
                chapters = Self.parseChapters(d.description)
                if current?.channelId == nil || current?.channelAvatar == nil {
                    current?.channelId = d.channel.id
                    current?.channelAvatar = d.channel.avatar
                    if let c = current { library.recordWatch(c) }
                }
                if queue.isEmpty { queue = library.filtered(d.related) }
            }
            segments = s
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        updateCaption(t)
        guard !segments.isEmpty, UserDefaults.standard.object(forKey: "sponsorBlock") as? Bool ?? true else { return }
        if let seg = segments.first(where: { t >= $0.start && t < $0.end - 0.5 }) {
            player.seek(to: CMTime(seconds: seg.end, preferredTimescale: 600))
            skippedNotice = String(localized: "Skipped \(seg.category.replacingOccurrences(of: "_", with: " "))")
            Task { try? await Task.sleep(for: .seconds(2.5)); skippedNotice = nil }
        }
    }

    private func ended() {
        saveProgress(finished: true)
        guard UserDefaults.standard.object(forKey: "videoAutoplay") as? Bool ?? true, !queue.isEmpty else { return }
        playNext()
    }

    func playNext() {
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let rest = queue
        current = nil
        open(next, queue: rest)
    }

    // MARK: Audio tracks (dubbing)

    private func loadAudioTracks(_ item: AVPlayerItem, originalLanguage: String?) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), group.options.count > 1 else { return }
        audibleGroup = group
        audibleOptions = [:]
        var options: [AudioTrackOption] = []
        for option in group.options {
            // The HLS NAME ("العربية - dubbed", "American English - original") is the option's title metadata;
            // displayName is only the localized language.
            var title = ""
            if let item = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first,
               let value = try? await item.load(.stringValue) {
                title = value
            }
            let tag = option.extendedLanguageTag ?? option.locale?.identifier
            let lowerTitle = title.lowercased()
            let isOriginal = lowerTitle.contains("original")
                || (!lowerTitle.contains("dubbed") && tag != nil && tag == originalLanguage)
            let name = tag.flatMap { Locale.current.localizedString(forIdentifier: $0) } ?? option.displayName
            guard audibleOptions[name] == nil else { continue }
            audibleOptions[name] = option
            var track = AudioTrackOption(name: name, language: tag, isOriginal: isOriginal, isDubbed: lowerTitle.contains("dubbed"))
            track.rawName = name
            options.append(track)
        }
        audioTracks = options.sorted { $0.isOriginal && !$1.isOriginal }
        if let original = audioTracks.first(where: \.isOriginal) ?? audioTracks.first { selectAudio(original) }
    }

    func selectAudio(_ track: AudioTrackOption) {
        guard let group = audibleGroup, let option = audibleOptions[track.rawName] else { return }
        player.currentItem?.select(option, in: group)
        selectedAudio = track
    }

    // MARK: Captions

    func selectCaption(_ track: CaptionTrack?) {
        selectedCaption = track
        UserDefaults.standard.set(track?.language, forKey: "captionLanguage")
    }

    private func loadCaptions() async {
        cues = []
        currentCaption = nil
        guard let track = selectedCaption,
              let (data, _) = try? await URLSession.shared.data(from: track.url),
              let text = String(data: data, encoding: .utf8), selectedCaption == track else { return }
        cues = Self.parseVTT(text)
        updateCaption(player.currentTime().seconds)
    }

    private func updateCaption(_ t: Double) {
        guard !cues.isEmpty else { if currentCaption != nil { currentCaption = nil }; return }
        let text = cues.last { t >= $0.start && t < $0.end }?.text
        if text != currentCaption { currentCaption = text }
    }

    nonisolated static func parseVTT(_ text: String) -> [CaptionCue] {
        func seconds(_ s: Substring) -> Double? {
            let parts = s.split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
            guard !parts.contains(where: { $0 == nil }) else { return nil }
            return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
        }
        var cues: [CaptionCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let ends = lines[timing].components(separatedBy: "-->")
            guard ends.count == 2,
                  let start = seconds(Substring(ends[0].trimmingCharacters(in: .whitespaces))),
                  let end = seconds(Substring(ends[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")) else { continue }
            let body = lines[(timing + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .decodingHTMLEntities
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            // Auto-generated tracks repeat the previous line as a rolling window; keep the newest line only.
            if let last = cues.last, body.hasPrefix(last.text), end - start < 0.05 { continue }
            cues.append(CaptionCue(start: start, end: end, text: body))
        }
        return cues
    }

    func seek(to seconds: Double) { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }

    func saveProgress(finished: Bool = false) {
        guard let id = current?.id else { return }
        let t = player.currentTime().seconds
        library.savePosition(id, finished ? 0 : (t.isFinite ? t : 0))
    }

    private static func metadata(title: String, artist: String) -> [AVMetadataItem] {
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem(); m.identifier = id; m.value = value as NSString; m.extendedLanguageTag = "und"; return m
        }
        return [item(.commonIdentifierTitle, title), item(.commonIdentifierArtist, artist)]
    }

    static func parseChapters(_ description: String) -> [Chapter] {
        let regex = try! NSRegularExpression(pattern: #"^\s*[\(\[]?((?:\d{1,2}:)?\d{1,2}:\d{2})[\)\]]?\s*[-–—:]?\s*(.+)$"#, options: .anchorsMatchLines)
        let ns = description as NSString
        let chapters = regex.matches(in: description, range: NSRange(location: 0, length: ns.length)).compactMap { m -> Chapter? in
            guard let t = ns.substring(with: m.range(at: 1)).durationSeconds else { return nil }
            return Chapter(time: Double(t), title: ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces))
        }
        guard chapters.count >= 3, chapters.first?.time == 0 else { return [] }
        return chapters
    }

    nonisolated static func sponsorSegments(_ videoId: String) async -> [SponsorSegment] {
        let categories = #"["sponsor","selfpromo","interaction","intro","outro","music_offtopic"]"#
        guard let cats = categories.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://sponsor.ajay.app/api/skipSegments?videoID=\(videoId)&categories=\(cats)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return J(data: data).array.compactMap { s in
            let seg = s["segment"].array
            guard seg.count == 2, let a = seg[0].double, let b = seg[1].double, b > a else { return nil }
            return SponsorSegment(start: a, end: b, category: s["category"].string ?? "sponsor")
        }
    }
}
