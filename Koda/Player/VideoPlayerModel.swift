import AVFoundation
import AVKit
import GoogleCast
import MediaPlayer
import Observation
import os
import SwiftUI
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
///
/// Two queues: `userQueue` holds what the viewer chose (Play Next, Add to Queue, Play all) and always
/// plays first; `queue` is the automatic Up next (the list a video was opened from, else its related
/// videos), which only plays by itself when the autoplay setting allows and the viewer queued nothing.
/// When the viewer's queue runs out, playback stops.
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
    var queue: [Video] = [] { didSet { updateNowPlaying() } }
    /// The viewer's own queue, saved across launches.
    var userQueue: [Video] = VideoPlayerModel.loadUserQueue() {
        didSet { saveUserQueue(); updateNowPlaying() }
    }
    /// The current video came from the viewer's queue (or Play all): when that queue is empty at its
    /// end, playback stops instead of autoplaying a related video.
    private(set) var playingFromUserQueue = false
    var isPictureInPictureActive = false
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
    @ObservationIgnored private var jumpObserver: NSObjectProtocol?
    @ObservationIgnored private var speedObservation: NSKeyValueObservation?
    /// The video played to its end and nothing followed it.
    @ObservationIgnored private var stoppedAtEnd = false
    /// The stream's length from the player response, until the item knows its own.
    @ObservationIgnored private var knownDuration: Double = 0
    @ObservationIgnored private var artworkCache: (id: String, artwork: MPMediaItemArtwork)?
    @ObservationIgnored private var artworkLoadingId: String?
    /// The receiver's position while this video is cast.
    private(set) var castPosition: Double = 0
    /// The HLS stream of the current video, for casting it.
    @ObservationIgnored private var castStream: (id: String, url: URL, isLive: Bool)?
    @ObservationIgnored private var castTask: Task<Void, Never>?

    var library: LibraryStore { .shared }

    init() {
        player.allowsExternalPlayback = true
        // Koda chooses the audio rendition itself: the original track unless the viewer picks a dub,
        // rather than AVPlayer's automatic match to the device language.
        player.appliesMediaSelectionCriteriaAutomatically = false
        // Keep the sound going when the app leaves the screen without Picture in Picture.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        rateObservation = player.observe(\.timeControlStatus) { @Sendable [weak self] p, _ in
            Task { @MainActor in self?.playbackStateChanged(p.timeControlStatus != .paused) }
        }
        speedObservation = player.observe(\.rate) { @Sendable [weak self] _, _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        // Any seek (scrubbing, chapters, SponsorBlock, the Lock Screen) moves the published position.
        jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: nil, queue: .main) { [weak self] note in
            let jumped = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let jumped, let current = self.player.currentItem, jumped == ObjectIdentifier(current) else { return }
                self.updateNowPlaying()
            }
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
        open(video, queue: queue, fromUserQueue: false)
    }

    private func open(_ video: Video, queue: [Video], fromUserQueue: Bool) {
        NowPlayingOwner.claim(.video)
        MusicPlayer.shared.pause()
        if current?.id == video.id { isPresented = true; return }
        saveProgress()
        playingFromUserQueue = fromUserQueue
        stoppedAtEnd = false
        knownDuration = video.durationText?.durationSeconds.map(Double.init) ?? 0
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
        updateNowPlaying()
    }

    func close() {
        saveProgress()
        if isCasting { CastManager.shared.stopMedia() }
        castTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        current = nil
        details = nil
        isPresented = false
        playingFromUserQueue = false
        stoppedAtEnd = false
        // Now Playing and the Live Activity go back to the music, or away if there is none.
        updateNowPlaying()
        NowPlayingOwner.claim(.music)
        MusicPlayer.shared.updateNowPlaying()
    }

    // MARK: Transport

    func play() {
        guard current != nil else { return }
        NowPlayingOwner.claim(.video)
        if MusicPlayer.shared.isPlaying { MusicPlayer.shared.pause() }
        if CastManager.shared.isConnected {
            if isCasting, CastManager.shared.lastStatus?.state != .idle {
                CastManager.shared.play()
                isPlaying = true
                updateNowPlaying()
            } else {
                castCurrent(at: stoppedAtEnd ? 0 : elapsed, autoplay: true)
            }
            stoppedAtEnd = false
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        if stoppedAtEnd { stoppedAtEnd = false; seek(to: 0) }
        player.play()
    }

    func pause() {
        player.pause()
        if isCasting { CastManager.shared.pause(); isPlaying = false; updateNowPlaying() }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func setRate(_ rate: Float) {
        player.defaultRate = rate
        if isCasting { CastManager.shared.setRate(rate); return }
        if isPlaying { player.rate = rate }
    }

    /// Widget, Live Activity and Control Center buttons while the video owns Now Playing.
    func handle(_ command: PlaybackCommand) {
        switch command {
        case .toggle: togglePlay()
        case .next: if hasNext { playNext() }
        case .previous: seek(to: 0)
        case .like: if let current { library.toggleVideoLike(current) }
        }
    }

    private func playbackStateChanged(_ playing: Bool) {
        // While cast, the paused local player says nothing about playback.
        guard !isCasting else { return }
        isPlaying = playing
        if playing, !NowPlayingOwner.isVideo, current != nil {
            // Started from the video's own controls while music had Now Playing.
            NowPlayingOwner.claim(.video)
            if MusicPlayer.shared.isPlaying { MusicPlayer.shared.pause() }
        }
        updateNowPlaying()
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
                // A downloaded video plays from its file, without the network; subtitles still come
                // from YouTube when there is a connection.
                if let local = VideoDownloadManager.shared.localURL(for: video.id) {
                    let asset = AVURLAsset(url: local)
                    let item = AVPlayerItem(asset: asset)
                    item.externalMetadata = Self.metadata(title: video.title, artist: video.channel)
                    player.replaceCurrentItem(with: item)
                    await loadAudioTracks(item, originalLanguage: nil)
                    let duration = (try? await asset.load(.duration).seconds) ?? 0
                    if duration > 0 { knownDuration = duration }
                    let resume = library.data.videoHistory.first { $0.video.id == video.id }?.position ?? 0
                    if resume > 10, duration - resume > 20 {
                        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                    }
                    guard !Task.isCancelled, current?.id == video.id else { return }
                    // Music started while this loaded: it keeps playing, and the video waits.
                    startPlayback()
                    isLoading = false
                    errorMessage = nil
                    if let info = try? await InnerTube.shared.player(videoId: video.id, quick: true), current?.id == video.id {
                        applyCaptions(info.captions)
                    }
                } else {
                    let info = try await InnerTube.shared.player(videoId: video.id)
                    guard !Task.isCancelled, current?.id == video.id else { return }
                    guard let url = info.hlsURL else { throw InnerTubeError.noStream }
                    castStream = (video.id, url, info.isLive)
                    if info.duration > 0 { knownDuration = Double(info.duration) }
                    let item = AVPlayerItem(asset: AVURLAsset(url: url))
                    item.preferredMaximumResolution = quality.size
                    item.externalMetadata = Self.metadata(title: info.title, artist: info.author)
                    player.replaceCurrentItem(with: item)
                    applyCaptions(info.captions)
                    await loadAudioTracks(item, originalLanguage: info.originalAudioLanguage)
                    let resume = library.data.videoHistory.first { $0.video.id == video.id }?.position ?? 0
                    if resume > 10, info.duration - resume > 20 {
                        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                    }
                    guard !Task.isCancelled, current?.id == video.id else { return }
                    startPlayback()
                    isLoading = false
                    errorMessage = nil
                }
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
            updateNowPlaying()
        }
    }

    private func applyCaptions(_ captions: [CaptionTrack]) {
        let preferredLanguage = Locale.current.language.languageCode?.identifier ?? "en"
        captionTracks = captions.sorted { a, b in
            let ra = (a.language.hasPrefix(preferredLanguage) ? 0 : 2) + (a.isAutoGenerated ? 1 : 0)
            let rb = (b.language.hasPrefix(preferredLanguage) ? 0 : 2) + (b.isAutoGenerated ? 1 : 0)
            return ra < rb
        }
        // Subtitles start off unless the viewer asked for them to turn on by themselves.
        if UserDefaults.standard.bool(forKey: "autoSubtitles"),
           let preferred = UserDefaults.standard.string(forKey: "captionLanguage"),
           let track = captions.first(where: { $0.language == preferred && !$0.isAutoGenerated })
            ?? captions.first(where: { $0.language == preferred }) {
            selectedCaption = track
        } else {
            selectedCaption = nil
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite, !isCasting else { return }
        updateCaption(t)
        skipSponsorSegment(at: t)
    }

    private func skipSponsorSegment(at t: Double) {
        guard !segments.isEmpty, UserDefaults.standard.object(forKey: "sponsorBlock") as? Bool ?? true else { return }
        if let seg = segments.first(where: { t >= $0.start && t < $0.end - 0.5 }) {
            seek(to: seg.end)
            skippedNotice = String(localized: "Skipped \(seg.category.replacingOccurrences(of: "_", with: " "))")
            Task { try? await Task.sleep(for: .seconds(2.5)); skippedNotice = nil }
        }
    }

    private func ended() {
        saveProgress(finished: true)
        // The viewer's queue plays whatever the autoplay setting says.
        if !userQueue.isEmpty { playNext(); return }
        // It ran out: stop, rather than carry on with a related video.
        guard !playingFromUserQueue, UserDefaults.standard.object(forKey: "videoAutoplay") as? Bool ?? true, !queue.isEmpty else {
            stoppedAtEnd = true
            updateNowPlaying()
            return
        }
        playNext()
    }

    /// Whether next has something to play: the viewer's queue, else (unless that queue just ran out) Up next.
    var hasNext: Bool { !userQueue.isEmpty || (!playingFromUserQueue && !queue.isEmpty) }

    /// The automatic Up next, when it is what plays after this video.
    var autoNext: Video? { userQueue.isEmpty && !playingFromUserQueue ? queue.first : nil }

    func playNext() {
        if !userQueue.isEmpty {
            playFromUserQueue(userQueue.removeFirst())
            return
        }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        let rest = queue
        current = nil
        open(next, queue: rest)
    }

    // MARK: The viewer's queue

    /// Whether queueing a video starts it right away: nothing is playing, or the last video finished.
    var queueStartsNow: Bool { current == nil || stoppedAtEnd }

    /// True when the video was queued, false when it started playing because nothing else was.
    @discardableResult func addToQueue(_ video: Video) -> Bool { enqueue(video, next: false) }

    @discardableResult func playNextInQueue(_ video: Video) -> Bool { enqueue(video, next: true) }

    /// Nothing to wait for (no video, or the last one finished): the queue starts now.
    private func enqueue(_ video: Video, next: Bool) -> Bool {
        if queueStartsNow {
            if next || userQueue.isEmpty { playFromUserQueue(video); return false }
            userQueue.removeAll { $0.id == video.id }
            userQueue.append(video)
            playNext()
            return false
        }
        guard video.id != current?.id else { return true }
        userQueue.removeAll { $0.id == video.id }
        if next { userQueue.insert(video, at: 0) } else { userQueue.append(video) }
        return true
    }

    /// Play all: the first video now, the rest in the viewer's queue, then stop.
    func playAll(_ videos: [Video]) {
        guard let first = videos.first else { return }
        var seen: Set<String> = [first.id]
        userQueue = videos.dropFirst().filter { seen.insert($0.id).inserted }
        playFromUserQueue(first)
    }

    func playQueued(at index: Int) {
        guard userQueue.indices.contains(index) else { return }
        playFromUserQueue(userQueue.remove(at: index))
    }

    func moveQueue(from source: IndexSet, to destination: Int) { userQueue.move(fromOffsets: source, toOffset: destination) }

    func removeFromQueue(at offsets: IndexSet) { userQueue.remove(atOffsets: offsets) }

    func clearQueue() { userQueue = [] }

    private func playFromUserQueue(_ video: Video) {
        // Up next is rebuilt from this video's related videos.
        queue = []
        if current?.id == video.id { current = nil }
        open(video, queue: [], fromUserQueue: true)
    }

    private static let userQueueKey = "videoUserQueue"

    private static func loadUserQueue() -> [Video] {
        guard let data = UserDefaults.standard.data(forKey: userQueueKey) else { return [] }
        return (try? JSONDecoder().decode([Video].self, from: data)) ?? []
    }

    private func saveUserQueue() {
        UserDefaults.standard.set(try? JSONEncoder().encode(userQueue), forKey: Self.userQueueKey)
    }

    // MARK: Now Playing

    var nowPlayingTitle: String { details?.title ?? current?.title ?? "" }
    var nowPlayingChannel: String { details?.channel.name ?? current?.channel ?? "" }

    var elapsed: Double {
        if isCasting { return castPosition }
        let t = player.currentTime().seconds
        return t.isFinite ? max(t, 0) : 0
    }

    var duration: Double {
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { return d }
        return knownDuration
    }

    /// Publishes the video to the Lock Screen, Control Center and the Live Activity while it owns them.
    func updateNowPlaying() {
        guard NowPlayingOwner.isVideo else { return }
        let commands = MPRemoteCommandCenter.shared()
        commands.nextTrackCommand.isEnabled = hasNext
        commands.previousTrackCommand.isEnabled = current != nil
        defer { LiveActivitySync.updateVideo(self) }
        guard let video = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }
        let isLive = video.isLive || (player.currentItem?.duration.isIndefinite ?? false)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPMediaItemPropertyArtist: nowPlayingChannel,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(player.rate == 0 ? player.defaultRate : player.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.defaultRate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
        if !isLive { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let cached = artworkCache, cached.id == video.id {
            info[MPMediaItemPropertyArtwork] = cached.artwork
        } else if let url = video.thumbnailURL, artworkLoadingId != video.id {
            artworkLoadingId = video.id
            Task {
                let image = (try? await URLSession.shared.data(from: url)).flatMap { UIImage(data: $0.0) }.map(Self.removingLetterbox)
                if self.artworkLoadingId == video.id { self.artworkLoadingId = nil }
                // The video may have changed while the thumbnail loaded.
                guard let image, self.current?.id == video.id else { return }
                self.artworkCache = (video.id, Self.artwork(image))
                LiveActivitySync.saveVideoArtwork(image, videoId: video.id)
                self.updateNowPlaying()
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    /// MediaPlayer asks for the image on its own queue, so the closure must not be main-actor isolated.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    /// YouTube's hqdefault thumbnails are 4:3 with black bars around a 16:9 picture: keep the picture.
    nonisolated static func removingLetterbox(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage, abs(Double(cg.width) / Double(max(cg.height, 1)) - 4.0 / 3.0) < 0.05 else { return image }
        let bar = Int(Double(cg.height) * 0.125)
        guard let cropped = cg.cropping(to: CGRect(x: 0, y: bar, width: cg.width, height: cg.height - 2 * bar)) else { return image }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
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
        // A long auto-generated track is thousands of cues with a regex each: parse it off the main thread.
        let parsed = await Task.detached(priority: .userInitiated) { Self.parseVTT(text) }.value
        guard selectedCaption == track else { return }
        cues = parsed
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

    func seek(to seconds: Double) {
        if isCasting {
            CastManager.shared.seek(to: seconds)
            castPosition = seconds
            updateNowPlaying()
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    func saveProgress(finished: Bool = false) {
        guard let id = current?.id else { return }
        let t = elapsed
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

// MARK: Google Cast

extension VideoPlayerModel {
    /// The receiver plays this video: transport goes there.
    var isCasting: Bool { CastManager.shared.isCastingVideo(current?.id) }

    /// The loaded video starts: on the receiver while a Cast session is up, else here.
    fileprivate func startPlayback() {
        guard NowPlayingOwner.isVideo else { return }
        if CastManager.shared.isConnected {
            let t = player.currentTime().seconds
            castCurrent(at: t.isFinite ? t : 0, autoplay: true)
        } else {
            player.play()
        }
    }

    /// Plays the current video on the receiver, through the proxy (googlevideo's HLS has no CORS
    /// headers), from `position` or where it is here.
    func castCurrent(at position: Double? = nil, autoplay: Bool? = nil) {
        guard let video = current else { return }
        let start = position ?? elapsed
        let play = autoplay ?? (isPlaying || player.timeControlStatus != .paused)
        player.pause()
        castTask?.cancel()
        castTask = Task {
            do {
                let stream: (id: String, url: URL, isLive: Bool)
                if let known = castStream, known.id == video.id {
                    stream = known
                } else {
                    // A downloaded video plays from its file here; the receiver streams it from YouTube.
                    let info = try await InnerTube.shared.player(videoId: video.id)
                    guard let url = info.hlsURL else { throw InnerTubeError.noStream }
                    stream = (video.id, url, info.isLive)
                    castStream = stream
                }
                let endpoint = try await CastManager.shared.proxyEndpoint()
                guard !Task.isCancelled, current?.id == video.id, CastManager.shared.isConnected else { return }
                let url = CastProxyServer.shared.playlistURL(for: stream.url, host: endpoint.host, port: endpoint.port)
                let isLive = stream.isLive || video.isLive
                // YouTube's HLS: MPEG-TS video segments with separate packed-AAC audio renditions
                // (checked with curl); live streams mux the audio into the TS segments.
                let item = CastItem(id: video.id, url: url, contentType: "application/x-mpegurl", title: nowPlayingTitle,
                                    subtitle: nowPlayingChannel, artwork: video.thumbnailURL, duration: duration,
                                    isVideo: true, isLive: isLive,
                                    hlsSegmentFormat: isLive ? .TS : .AAC, hlsVideoSegmentFormat: .MPEG2_TS)
                CastManager.shared.loadVideo(item, position: start, autoplay: play, rate: player.defaultRate)
                castPosition = start
                isPlaying = play
                isLoading = false
                updateNowPlaying()
            } catch {
                guard !Task.isCancelled, (error as? URLError)?.code != .cancelled else { return }
                castLog.error("video cast failed: \(String(describing: error), privacy: .public)")
                AppState.current?.showToast("Couldn't cast this video: \(error.localizedDescription)")
            }
        }
    }

    func castStatusChanged(_ status: CastStatus, id: String) {
        guard isCasting, id == current?.id else { return }
        switch status.state {
        case .playing: isPlaying = true
        case .paused: isPlaying = false
        case .buffering: break
        case .idle:
            isPlaying = false
            if status.idleReason == .finished {
                castPosition = 0
                ended()
                return
            }
        }
        if status.state != .idle, status.position.isFinite { castPosition = status.position }
        updateNowPlaying()
    }

    func castTick(_ position: Double, id: String) {
        guard isCasting, id == current?.id, isPlaying else { return }
        castPosition = position
        skipSponsorSegment(at: position)
    }

    func castLoadFailed(id: String) {
        guard id == current?.id else { return }
        isPlaying = false
        updateNowPlaying()
    }

    /// The session ended: the video continues here where the receiver was.
    func castEnded(id: String, at position: Double, wasPlaying: Bool) {
        guard id == current?.id else { return }
        castPosition = 0
        if position > 0 { player.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
        if wasPlaying, NowPlayingOwner.isVideo { player.play() } else { isPlaying = false }
        updateNowPlaying()
    }
}

