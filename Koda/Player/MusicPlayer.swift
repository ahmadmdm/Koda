import SwiftUI
import AVFoundation
import MediaPlayer
import Observation
import UIKit
import os

nonisolated let playbackLog = Logger(subsystem: "com.koda.ios", category: "playback")

enum RepeatMode: String, CaseIterable { case off, all, one
    var icon: String { self == .one ? "repeat.1" : "repeat" }
}

/// The shared music queue and its AVPlayer: play next, add to queue, reorder,
/// remove, shuffle and repeat that survive restarts, radio that extends the
/// queue, speed, sleep timer, volume normalisation, lock-screen controls and
/// play statistics.
@MainActor
@Observable
final class MusicPlayer {
    static let shared = MusicPlayer()

    private(set) var queue: [Song] = [] { didSet { queueChanged = true; syncCurrentId() } }
    private(set) var index: Int = 0 { didSet { syncCurrentId() } }
    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
    /// The current song's id, stored apart from `queue`: song rows compare against it, and reading
    /// `current` would redraw every visible row whenever the queue grows or a duration is filled in.
    private(set) var currentId: String?
    var upNext: [Song] { queue.indices.contains(index + 1) ? Array(queue[(index + 1)...]) : [] }

    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var errorMessage: String?

    var shuffle = UserDefaults.standard.bool(forKey: "shuffle") { didSet { UserDefaults.standard.set(shuffle, forKey: "shuffle") } }
    var repeatMode = RepeatMode(rawValue: UserDefaults.standard.string(forKey: "repeatMode") ?? "off") ?? .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "repeatMode") }
    }
    var rate: Float = 1 { didSet { if isPlaying { player.rate = rate }; updateNowPlaying() } }
    var radioEnabled = true

    var sleepTimerEnd: Date?
    var sleepAtEndOfTrack = false
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var resolved: [String: (url: URL, loudness: Double?, expires: Date)] = [:]
    @ObservationIgnored private var listenedSeconds: Double = 0
    @ObservationIgnored private var playRecordIndex: Int?
    @ObservationIgnored private var lastRecordedSeconds: Double = 0
    @ObservationIgnored private var lastTick: Double = 0
    @ObservationIgnored private var artworkCache: (String, MPMediaItemArtwork)?
    @ObservationIgnored private var radioSeed: String?
    /// The song the listener just picked. If it cannot play, say so and stay on it: skipping on
    /// to the radio's next song made it look as if a different song had been chosen.
    @ObservationIgnored private var chosenId: String?
    /// Songs whose refused stream URL was already resolved again once, so a failing song doesn't loop.
    @ObservationIgnored private var retriedIds: Set<String> = []
    /// Bumped whenever a new queue replaces the old one, so radio results for the old one are dropped.
    @ObservationIgnored private var queueGeneration = 0
    /// Whether the listener wants sound: cleared by a pause during loading, so the load doesn't override it.
    @ObservationIgnored private var wantsPlayback = false
    /// The song the AVPlayer's current item was made for.
    @ObservationIgnored private var itemSongId: String?
    @ObservationIgnored private var wasPlayingBeforeInterruption = false
    @ObservationIgnored private var artworkLoadingId: String?
    /// Whether `queue` changed since the session last saved it, and which window of it was saved.
    @ObservationIgnored private var queueChanged = true
    @ObservationIgnored private var savedQueueStart = -1
    @ObservationIgnored private var savedPositionBucket = -1

    var library: LibraryStore { .shared }

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            // Compare identities, so the non-Sendable notification never crosses into the main actor.
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let ended, let current = self.player.currentItem, ended == ObjectIdentifier(current) else { return }
                self.trackEnded()
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .began {
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    self.isPlaying = false
                    self.updateNowPlaying()
                } else if type == .ended {
                    // Resume only what the interruption stopped, not music the listener had paused.
                    if options?.contains(.shouldResume) == true, self.wasPlayingBeforeInterruption { self.play() }
                    self.wasPlayingBeforeInterruption = false
                }
            }
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            guard reason == .oldDeviceUnavailable else { return }
            // Headphones unplugged or disconnected: AVPlayer pauses, so say so everywhere.
            MainActor.assumeIsolated {
                guard let self, self.isPlaying || self.wantsPlayback else { return }
                self.stopPlayback()
            }
        }
        // Going to the background, keep the play record's listened time current, which is otherwise
        // written every 30 seconds.
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPlayRecord() }
        }
        setupRemoteCommands()
        restoreSession()
        // The widgets and Live Activity may still show the previous run playing: show it paused.
        Task { WidgetSync.update(self) }
        PlaybackCommandCenter.handler = { [weak self] command in
            guard let self else { return }
            // Widget and Live Activity buttons act on whichever player owns Now Playing.
            if NowPlayingOwner.isVideo { VideoPlayerModel.shared.handle(command); return }
            switch command {
            case .toggle: self.togglePlay()
            case .next: self.next()
            case .previous: self.previous()
            case .like: if let song = self.current { self.library.toggleLike(song); self.updateNowPlaying() }
            }
        }
    }

    // MARK: Queue control

    func play(_ songs: [Song], startAt: Int = 0, shuffled: Bool = false, radio: Bool = false) {
        guard !songs.isEmpty else { return }
        playbackLog.info("play \(songs[startAt].id, privacy: .public) \(songs[startAt].title, privacy: .public) radio=\(radio)")
        commitListening()
        var list = songs
        var start = startAt
        if shuffled {
            let first = list.remove(at: startAt)
            list.shuffle()
            list.insert(first, at: 0)
            start = 0
            shuffle = true
        }
        queue = list
        index = min(start, list.count - 1)
        queueGeneration += 1
        let radio = radio && !songs[startAt].isLocal
        radioSeed = radio ? songs[startAt].id : nil
        chosenId = songs[startAt].id
        load(autoplay: true)
        if radio { Task { await extendWithRadio(seed: songs[startAt].id) } }
        saveSession()
    }

    func startRadio(from song: Song) {
        guard !song.isLocal else { return }
        play([song], radio: true)
    }

    func playNext(_ songs: [Song]) {
        guard current != nil else { play(songs); return }
        let ids = Set(songs.map(\.id))
        var rest = queue.enumerated().filter { $0.offset <= index || !ids.contains($0.element.id) }.map(\.element)
        let insertAt = min(index + 1, rest.count)
        rest.insert(contentsOf: songs.filter { $0.id != current?.id }, at: insertAt)
        queue = rest
        saveSession()
    }

    func addToQueue(_ songs: [Song]) {
        guard current != nil else { play(songs); return }
        let existing = Set(queue.map(\.id))
        queue += songs.filter { !existing.contains($0.id) }
        saveSession()
    }

    func move(from source: IndexSet, to destination: Int) {
        // Offsets are relative to `upNext`.
        var next = upNext
        next.move(fromOffsets: source, toOffset: destination)
        queue = Array(queue[...index]) + next
        saveSession()
    }

    func removeFromUpNext(at offsets: IndexSet) {
        var next = upNext
        next.remove(atOffsets: offsets)
        queue = Array(queue[...index]) + next
        saveSession()
    }

    func jump(toUpNext offset: Int) {
        let target = index + 1 + offset
        guard offset >= 0, queue.indices.contains(target) else { return }
        commitListening()
        index = target
        load(autoplay: true)
        saveSession()
    }

    func clearUpNext() { queue = Array(queue[...index]); saveSession() }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let song = current else { return }
        wantsPlayback = true
        claimAudio()
        if player.currentItem == nil || itemSongId != song.id {
            // The player holds nothing, or still the previous song: let the running load start this
            // one, or load it at the saved position.
            if isLoading { isPlaying = true; updateNowPlaying() } else { load(autoplay: true, resumeAt: currentTime) }
            return
        }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
        haptic()
    }

    func pause() {
        stopPlayback()
        haptic()
    }

    private func stopPlayback() {
        wantsPlayback = false
        player.pause()
        isPlaying = false
        updateNowPlaying()
        saveSession()
    }

    /// A minimized or Picture in Picture video would play over the music, and it leaves the
    /// session set up for movies.
    private func claimAudio() {
        NowPlayingOwner.claim(.music)
        VideoPlayerModel.shared.player.pause()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
    }

    func next() {
        commitListening()
        if repeatMode == .one { repeatMode = .all }
        if index + 1 < queue.count { index += 1 }
        else if repeatMode == .all { index = 0 }
        else { Task { await extendWithRadio(seed: current?.id, thenAdvance: true) }; return }
        load(autoplay: true)
        saveSession()
        haptic()
    }

    func previous() {
        if currentTime > 3 { seek(to: 0); return }
        commitListening()
        if index > 0 { index -= 1 } else { seek(to: 0); return }
        load(autoplay: true)
        saveSession()
        haptic()
    }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
        lastTick = seconds
        updateNowPlaying()
    }

    func skip(by seconds: Double) { seek(to: min(max(0, currentTime + seconds), duration)) }

    func toggleShuffle() {
        shuffle.toggle()
        if shuffle, queue.count > index + 2 {
            queue = Array(queue[...index]) + upNext.shuffled()
            saveSession()
        }
        haptic()
    }

    func cycleRepeat() {
        let all = RepeatMode.allCases
        repeatMode = all[(all.firstIndex(of: repeatMode)! + 1) % all.count]
        updateNowPlaying()
        haptic()
    }

    // MARK: Sleep timer

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepAtEndOfTrack = false
        guard let minutes else { sleepTimerEnd = nil; return }
        let end = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEnd = end
        sleepTask = Task {
            try? await Task.sleep(until: .now + .seconds(Double(minutes) * 60))
            guard !Task.isCancelled else { return }
            self.pause()
            self.sleepTimerEnd = nil
        }
    }

    func sleepAtEnd() { sleepTask?.cancel(); sleepTimerEnd = nil; sleepAtEndOfTrack = true }

    // MARK: Loading

    private func load(autoplay: Bool, resumeAt: Double = 0, retry: Bool = false) {
        guard let song = current else { return }
        loadTask?.cancel()
        statusObservation = nil
        if !retry { retriedIds.removeAll() }
        wantsPlayback = autoplay
        if autoplay { claimAudio() }
        errorMessage = nil
        isLoading = true
        currentTime = resumeAt
        lastTick = resumeAt
        playRecordIndex = nil
        lastRecordedSeconds = 0
        listenedSeconds = 0
        duration = Double(song.duration ?? 0)
        player.pause()
        updateNowPlaying()
        loadTask = Task { [self] in
            do {
                let (url, loudness) = try await streamURL(for: song)
                guard !Task.isCancelled, self.current?.id == song.id else { return }
                let asset = AVURLAsset(url: url, options: url.isFileURL ? nil : ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTube.userAgent(for: url)]])
                let item = AVPlayerItem(asset: asset)
                item.audioTimePitchAlgorithm = .timeDomain
                item.preferredForwardBufferDuration = 30
                // Observe before the item is in the player, with its current status, so a quick
                // readyToPlay or failure is never missed.
                self.statusObservation = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] item, _ in
                    Task { @MainActor in
                        guard let self, self.current?.id == song.id else { return }
                        if item.status == .readyToPlay {
                            self.isLoading = false
                            // YouTube's length is authoritative: AVPlayer misreads fragmented m4a.
                            let d = item.duration.seconds
                            if (self.current?.duration ?? 0) == 0, d.isFinite, d > 0 { self.duration = d }
                            self.updateNowPlaying()
                        } else if item.status == .failed {
                            self.handleFailure(song, error: item.error)
                        }
                    }
                }
                self.player.replaceCurrentItem(with: item)
                self.itemSongId = song.id
                self.applyNormalization(loudness)
                if resumeAt > 1 { await self.player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
                guard !Task.isCancelled else { return }
                // A pause while loading wins over the autoplay this load started with.
                if self.wantsPlayback {
                    self.player.playImmediately(atRate: self.rate)
                    self.isPlaying = true
                } else {
                    self.isLoading = false
                }
                self.updateNowPlaying()
                self.prefetchNext()
            } catch {
                // A superseded load ends in URLError.cancelled, not CancellationError: not a failure.
                guard !Task.isCancelled else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    if self.current?.id == song.id { self.isLoading = false }
                    return
                }
                playbackLog.error("stream failed \(song.id, privacy: .public): \(String(describing: error), privacy: .public)")
                guard self.current?.id == song.id else { return }
                self.isLoading = false
                self.isPlaying = false
                self.errorMessage = error.localizedDescription
                if song.id == self.chosenId {
                    AppState.current?.showToast("Couldn't play \(song.title): \(error.localizedDescription)")
                    return
                }
                // Skip what cannot play further down the queue, as the Android player does.
                if self.index + 1 < self.queue.count {
                    try? await Task.sleep(for: .seconds(1.5))
                    if !Task.isCancelled, self.current?.id == song.id { self.next() }
                }
            }
        }
    }

    private func handleFailure(_ song: Song, error: Error?) {
        playbackLog.error("item failed \(song.id, privacy: .public): \(String(describing: error), privacy: .public)")
        guard current?.id == song.id else { return }
        // A refused URL is usually the visitor token: forget it and resolve again once.
        if resolved[song.id] != nil, !retriedIds.contains(song.id) {
            retriedIds.insert(song.id)
            resolved[song.id] = nil
            UserDefaults.standard.removeObject(forKey: "visitorDataAt")
            load(autoplay: wantsPlayback, resumeAt: currentTime, retry: true)
        } else {
            isLoading = false
            isPlaying = false
            errorMessage = error?.localizedDescription ?? "Playback failed"
        }
    }

    private func streamURL(for song: Song) async throws -> (URL, Double?) {
        if song.isLocal {
            guard let file = LocalMusicLibrary.fileURL(for: song.id) else { throw CocoaError(.fileNoSuchFile) }
            return (file, nil)
        }
        if let local = DownloadManager.shared.localURL(for: song.id) { return (local, nil) }
        if let cached = resolved[song.id], cached.expires > .now { return (cached.url, cached.loudness) }
        let info: StreamInfo
        do {
            info = try await InnerTube.shared.player(videoId: song.id)
        } catch InnerTubeError.unplayable(let reason) {
            // A label can block one upload on some networks while another upload of the same
            // song plays: YouTube Music falls back to the song's other versions the same way.
            guard let alternate = await Self.alternateStream(for: song) else { throw InnerTubeError.unplayable(reason) }
            info = alternate
        }
        let low = UserDefaults.standard.string(forKey: "musicQuality") == "low"
        guard let url = (low ? info.lowAudioURL : info.audioURL) ?? info.audioURL ?? info.hlsURL else { throw InnerTubeError.noStream }
        // Expired URLs are never used again: drop them, so a long radio session doesn't keep them all.
        if resolved.count > 50 { resolved = resolved.filter { $0.value.expires > .now } }
        resolved[song.id] = (url, info.loudnessDb, Date().addingTimeInterval(5 * 3600))
        if let i = queue.firstIndex(where: { $0.id == song.id }), info.duration > 0 {
            queue[i].duration = Int(info.duration)
            if current?.id == song.id { duration = info.duration }
        }
        return (url, info.loudnessDb)
    }

    /// Another upload of the same song (its music video, a lyric video, a re-release) when the
    /// one picked is unavailable here. Matches on title and artist so a different song never plays.
    private static func alternateStream(for song: Song) async -> StreamInfo? {
        let query = "\(song.title) \(song.artist)"
        let songs = (try? await MusicAPI.search(query, filter: .songs).0) ?? []
        let videos = (try? await MusicAPI.search(query, filter: .videos).0) ?? []
        let wanted = normalized(song.title)
        let candidates = (songs + videos).compactMap(\.song).filter { candidate in
            candidate.id != song.id && !wanted.isEmpty
                && (normalized(candidate.title).contains(wanted) || wanted.contains(normalized(candidate.title)))
                && (song.artist.isEmpty || candidate.artist.localizedCaseInsensitiveContains(song.artist.components(separatedBy: ",")[0])
                    || song.artist.localizedCaseInsensitiveContains(candidate.artist))
        }
        for candidate in candidates.prefix(6) {
            if let info = try? await InnerTube.shared.player(videoId: candidate.id, quick: true) {
                playbackLog.info("alternate \(candidate.id, privacy: .public) for \(song.id, privacy: .public)")
                return info
            }
        }
        return nil
    }

    /// Title without diacritics, punctuation and brackets, for matching uploads of one song.
    private static func normalized(_ title: String) -> String {
        let base = title.components(separatedBy: CharacterSet(charactersIn: "([")).first ?? title
        return base.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(String.init).joined()
    }

    private func prefetchNext() {
        guard UserDefaults.standard.object(forKey: "preload") as? Bool ?? true else { return }
        let upcoming = upNext.prefix(2)
        Task {
            for song in upcoming where resolved[song.id] == nil && DownloadManager.shared.localURL(for: song.id) == nil {
                _ = try? await streamURL(for: song)
            }
        }
    }

    private func applyNormalization(_ loudness: Double?) {
        guard UserDefaults.standard.bool(forKey: "normalize"), let loudness, loudness > 0 else { player.volume = 1; return }
        // loudnessDb is how far above the reference the track is; attenuate by that much.
        player.volume = Float(min(1, pow(10, -loudness / 20)))
    }

    private func extendWithRadio(seed: String?, thenAdvance: Bool = false) async {
        guard radioEnabled, let seed, !seed.hasPrefix(LocalMusicLibrary.idPrefix) else { return }
        let generation = queueGeneration
        guard let songs = try? await MusicAPI.radio(for: seed) else { return }
        // The listener may have picked something else, or moved on, while the radio loaded.
        guard generation == queueGeneration, current?.id == seed else { return }
        if thenAdvance, index != queue.count - 1 { return }
        let existing = Set(queue.map(\.id))
        let fresh = songs.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        queue += fresh
        if thenAdvance { index += 1; load(autoplay: true) }
        saveSession()
    }

    private func trackEnded() {
        playbackLog.info("ended \(self.current?.id ?? "-", privacy: .public) at \(self.currentTime) of \(self.duration)")
        commitListening()
        if sleepAtEndOfTrack { sleepAtEndOfTrack = false; pause(); seek(to: 0); return }
        if repeatMode == .one { seek(to: 0); player.playImmediately(atRate: rate); return }
        if index + 1 >= queue.count, repeatMode != .all {
            Task { await extendWithRadio(seed: current?.id, thenAdvance: true) }
            if !radioEnabled || current?.isLocal == true { isPlaying = false }
            return
        }
        next()
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if isPlaying, seconds > lastTick, seconds - lastTick < 2 { listenedSeconds += seconds - lastTick; updatePlayRecord() }
        lastTick = seconds
        currentTime = seconds
        if (current?.duration ?? 0) == 0, let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 { duration = d }
        else if let known = current?.duration, known > 0, duration != Double(known) { duration = Double(known) }
        // Should the file run past YouTube's stated length, end the track there.
        if duration > 0, isPlaying, !isLoading, seconds >= duration + 1 { trackEnded() }
        if isPlaying && player.timeControlStatus == .paused && player.currentItem?.status == .readyToPlay && player.rate == 0 && !isLoading {
            // Paused by the system (route change, another app).
            isPlaying = false
            updateNowPlaying()
        }
        // Once every 10 seconds, not on each of the four ticks within that second.
        let bucket = Int(seconds) / 10
        if bucket != savedPositionBucket {
            savedPositionBucket = bucket
            UserDefaults.standard.set(seconds, forKey: "sessionPosition")
        }
    }

    /// A play is recorded once 10 seconds have been heard, then its listened time is kept
    /// current, so plays survive the app being closed mid-song. Each update rewrites the whole
    /// library file and redraws every view of the library, so it happens every 30 seconds (and when
    /// the app goes to the background), not every few.
    private func updatePlayRecord() {
        guard let song = current, listenedSeconds >= 10 else { return }
        if let i = playRecordIndex, library.data.plays.indices.contains(i), library.data.plays[i].song.id == song.id {
            guard listenedSeconds - lastRecordedSeconds >= 30 else { return }
            library.data.plays[i].seconds = listenedSeconds
        } else {
            library.recordPlay(song, seconds: listenedSeconds)
            playRecordIndex = library.data.plays.count - 1
        }
        lastRecordedSeconds = listenedSeconds
    }

    private func flushPlayRecord() {
        guard let song = current, let i = playRecordIndex, listenedSeconds > lastRecordedSeconds,
              library.data.plays.indices.contains(i), library.data.plays[i].song.id == song.id else { return }
        library.data.plays[i].seconds = listenedSeconds
        lastRecordedSeconds = listenedSeconds
    }

    private func commitListening() {
        if let i = playRecordIndex, library.data.plays.indices.contains(i), library.data.plays[i].song.id == current?.id {
            library.data.plays[i].seconds = listenedSeconds
        }
        playRecordIndex = nil
        lastRecordedSeconds = 0
        listenedSeconds = 0
    }

    // MARK: Session restoration

    private func saveSession() {
        WidgetSync.update(self)
        // Keep at most 300 songs, around the current one so it is always among them.
        let start = queue.count > 300 ? min(max(0, index - 50), queue.count - 300) : 0
        // Play, pause and skipping within the saved window leave the saved songs as they are: encode
        // them again only when they change.
        if queueChanged || start != savedQueueStart {
            if let data = try? JSONEncoder().encode(Array(queue[start...].prefix(300))) { UserDefaults.standard.set(data, forKey: "sessionQueue") }
            queueChanged = false
            savedQueueStart = start
        }
        UserDefaults.standard.set(index - start, forKey: "sessionIndex")
        UserDefaults.standard.set(currentTime, forKey: "sessionPosition")
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: "sessionQueue"),
              let saved = try? JSONDecoder().decode([Song].self, from: data), !saved.isEmpty else { return }
        queue = saved
        index = min(UserDefaults.standard.integer(forKey: "sessionIndex"), saved.count - 1)
        currentTime = UserDefaults.standard.double(forKey: "sessionPosition")
        duration = Double(current?.duration ?? 0)
        syncCurrentId()
        // What was just read is what is saved.
        queueChanged = false
        savedQueueStart = 0
    }

    private func syncCurrentId() {
        let id = current?.id
        if id != currentId { currentId = id }
    }

    /// Restore the previous session's player item without starting playback.
    func prepareRestoredSession() {
        guard current != nil, player.currentItem == nil else { return }
        load(autoplay: false, resumeAt: currentTime)
    }

    func stop() {
        commitListening()
        player.replaceCurrentItem(with: nil)
        itemSongId = nil
        wantsPlayback = false
        queueGeneration += 1
        queue = []; index = 0; isPlaying = false
        saveSession()
        if !NowPlayingOwner.isVideo { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
    }

    // MARK: Now playing / remote

    /// The targets are registered once; while a video owns Now Playing they forward to it.
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if NowPlayingOwner.isVideo { VideoPlayerModel.shared.play() } else { self?.play() } }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if NowPlayingOwner.isVideo { VideoPlayerModel.shared.pause() } else { self?.pause() } }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if NowPlayingOwner.isVideo { VideoPlayerModel.shared.handle(.toggle) } else { self?.togglePlay() } }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if NowPlayingOwner.isVideo { VideoPlayerModel.shared.handle(.next) } else { self?.next() } }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if NowPlayingOwner.isVideo { VideoPlayerModel.shared.handle(.previous) } else { self?.previous() } }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent {
                MainActor.assumeIsolated {
                    if NowPlayingOwner.isVideo { VideoPlayerModel.shared.seek(to: e.positionTime) } else { self?.seek(to: e.positionTime) }
                }
            }
            return .success
        }
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeShuffleModeCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { if (e.shuffleType != .off) != self?.shuffle { self?.toggleShuffle() } }
            return .success
        }
        center.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangeRepeatModeCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { self?.repeatMode = e.repeatType == .one ? .one : e.repeatType == .all ? .all : .off; self?.updateNowPlaying() }
            return .success
        }
        center.changePlaybackRateCommand.supportedPlaybackRates = [0.75, 1, 1.25, 1.5, 2]
        center.changePlaybackRateCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackRateCommandEvent else { return .commandFailed }
            MainActor.assumeIsolated { if NowPlayingOwner.isVideo { VideoPlayerModel.shared.setRate(e.playbackRate) } else { self?.rate = e.playbackRate } }
            return .success
        }
        center.likeCommand.localizedTitle = String(localized: "Like")
        center.likeCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { if let s = self?.current { self?.library.toggleLike(s) } }
            return .success
        }
    }

    /// MediaPlayer asks for the image on its own queue, so the closure must not be main-actor isolated.
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    func updateNowPlaying() {
        // A video owns the system's Now Playing: leave it alone, but keep the widgets current.
        guard !NowPlayingOwner.isVideo else { WidgetSync.update(self); return }
        guard let song = current else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.title,
            MPMediaItemPropertyArtist: song.artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let album = song.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let cached = artworkCache, cached.0 == song.id { info[MPMediaItemPropertyArtwork] = cached.1 }
        else if let url = song.artwork, artworkLoadingId != song.id {
            artworkLoadingId = song.id
            Task {
                // Shared with the artwork tint, which asks for the same cover at the same moment.
                let image = await ArtworkLoader.shared.fullImage(url)
                if self.artworkLoadingId == song.id { self.artworkLoadingId = nil }
                // The song may have changed while the artwork loaded: never show it on the next one.
                guard let image, self.current?.id == song.id else { return }
                let artwork = Self.artwork(image)
                self.artworkCache = (song.id, artwork)
                WidgetSync.saveArtwork(image, songId: song.id)
                self.updateNowPlaying()
            }
        }
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = index
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        MPRemoteCommandCenter.shared().likeCommand.isActive = library.isLiked(song)
        MPRemoteCommandCenter.shared().changeShuffleModeCommand.currentShuffleType = shuffle ? .items : .off
        MPRemoteCommandCenter.shared().changeRepeatModeCommand.currentRepeatType = repeatMode == .one ? .one : repeatMode == .all ? .all : .off
        WidgetSync.update(self)
    }

    private func haptic() {
        let level = UserDefaults.standard.string(forKey: "haptics") ?? "balanced"
        guard level != "off" else { return }
        let style: UIImpactFeedbackGenerator.FeedbackStyle = level == "subtle" ? .soft : level == "rich" ? .rigid : .light
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}
