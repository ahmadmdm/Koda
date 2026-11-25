import SwiftUI
import AVFoundation
import MediaPlayer
import Observation
import UIKit

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

    private(set) var queue: [Song] = []
    private(set) var index: Int = 0
    var current: Song? { queue.indices.contains(index) ? queue[index] : nil }
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
                if type == .began { self?.isPlaying = false }
                else if type == .ended, options?.contains(.shouldResume) == true { self?.play() }
            }
        }
        setupRemoteCommands()
        restoreSession()
        PlaybackCommandCenter.handler = { [weak self] command in
            guard let self else { return }
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
        radioSeed = radio ? songs[startAt].id : nil
        load(autoplay: true)
        if radio { Task { await extendWithRadio(seed: songs[startAt].id) } }
        saveSession()
    }

    func startRadio(from song: Song) {
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
        commitListening()
        index = index + 1 + offset
        load(autoplay: true)
        saveSession()
    }

    func clearUpNext() { queue = Array(queue[...index]); saveSession() }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard current != nil else { return }
        if player.currentItem == nil { load(autoplay: true); return }
        player.playImmediately(atRate: rate)
        isPlaying = true
        updateNowPlaying()
        haptic()
    }

    func pause() {
        player.pause()
        isPlaying = false
        updateNowPlaying()
        saveSession()
        haptic()
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

    private func load(autoplay: Bool, resumeAt: Double = 0) {
        guard let song = current else { return }
        loadTask?.cancel()
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
        loadTask = Task {
            do {
                let (url, loudness) = try await streamURL(for: song)
                guard !Task.isCancelled, self.current?.id == song.id else { return }
                let asset = AVURLAsset(url: url, options: url.isFileURL ? nil : ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTube.visionUA]])
                let item = AVPlayerItem(asset: asset)
                item.audioTimePitchAlgorithm = .timeDomain
                item.preferredForwardBufferDuration = 30
                self.player.replaceCurrentItem(with: item)
                self.applyNormalization(loudness)
                if resumeAt > 1 { await self.player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600)) }
                self.statusObservation = item.observe(\.status) { @Sendable [weak self] item, _ in
                    Task { @MainActor in
                        guard let self else { return }
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
                if autoplay {
                    self.player.playImmediately(atRate: self.rate)
                    self.isPlaying = true
                } else {
                    self.isLoading = false
                }
                self.updateNowPlaying()
                self.prefetchNext()
            } catch is CancellationError {
            } catch {
                guard self.current?.id == song.id else { return }
                self.isLoading = false
                self.isPlaying = false
                self.errorMessage = error.localizedDescription
                // Skip what cannot play, as the Android player does.
                if self.index + 1 < self.queue.count {
                    try? await Task.sleep(for: .seconds(1.5))
                    if self.current?.id == song.id { self.next() }
                }
            }
        }
    }

    private func handleFailure(_ song: Song, error: Error?) {
        guard current?.id == song.id else { return }
        // A refused URL is usually the visitor token: forget it and resolve again once.
        if resolved[song.id] != nil {
            resolved[song.id] = nil
            UserDefaults.standard.removeObject(forKey: "visitorDataAt")
            load(autoplay: true, resumeAt: currentTime)
        } else {
            isLoading = false
            isPlaying = false
            errorMessage = error?.localizedDescription ?? "Playback failed"
        }
    }

    private func streamURL(for song: Song) async throws -> (URL, Double?) {
        if let local = DownloadManager.shared.localURL(for: song.id) { return (local, nil) }
        if let cached = resolved[song.id], cached.expires > .now { return (cached.url, cached.loudness) }
        let info = try await InnerTube.shared.player(videoId: song.id)
        let low = UserDefaults.standard.string(forKey: "musicQuality") == "low"
        guard let url = (low ? info.lowAudioURL : info.audioURL) ?? info.audioURL ?? info.hlsURL else { throw InnerTubeError.noStream }
        resolved[song.id] = (url, info.loudnessDb, Date().addingTimeInterval(5 * 3600))
        if let i = queue.firstIndex(where: { $0.id == song.id }), info.duration > 0 {
            queue[i].duration = Int(info.duration)
            if current?.id == song.id { duration = info.duration }
        }
        return (url, info.loudnessDb)
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
        guard radioEnabled, let seed else { return }
        guard let songs = try? await MusicAPI.radio(for: seed) else { return }
        let existing = Set(queue.map(\.id))
        let fresh = songs.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return }
        queue += fresh
        if thenAdvance { index += 1; load(autoplay: true) }
        saveSession()
    }

    private func trackEnded() {
        commitListening()
        if sleepAtEndOfTrack { sleepAtEndOfTrack = false; pause(); seek(to: 0); return }
        if repeatMode == .one { seek(to: 0); player.playImmediately(atRate: rate); return }
        if index + 1 >= queue.count, repeatMode != .all {
            Task { await extendWithRadio(seed: current?.id, thenAdvance: true) }
            if !radioEnabled { isPlaying = false }
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
        else if let known = current?.duration, known > 0 { duration = Double(known) }
        // Should the file run past YouTube's stated length, end the track there.
        if duration > 0, isPlaying, !isLoading, seconds >= duration + 1 { trackEnded() }
        if isPlaying && player.timeControlStatus == .paused && player.currentItem?.status == .readyToPlay && player.rate == 0 && !isLoading {
            // Paused by the system (route change, another app).
            isPlaying = false
            updateNowPlaying()
        }
        if Int(seconds) % 10 == 0 { UserDefaults.standard.set(seconds, forKey: "sessionPosition") }
    }

    /// A play is recorded once 10 seconds have been heard, then its listened time is kept
    /// current, so plays survive the app being closed mid-song.
    private func updatePlayRecord() {
        guard let song = current, listenedSeconds >= 10 else { return }
        if let i = playRecordIndex, library.data.plays.indices.contains(i), library.data.plays[i].song.id == song.id {
            guard listenedSeconds - lastRecordedSeconds >= 5 else { return }
            library.data.plays[i].seconds = listenedSeconds
        } else {
            library.recordPlay(song, seconds: listenedSeconds)
            playRecordIndex = library.data.plays.count - 1
        }
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
        if let data = try? JSONEncoder().encode(Array(queue.prefix(300))) { UserDefaults.standard.set(data, forKey: "sessionQueue") }
        UserDefaults.standard.set(index, forKey: "sessionIndex")
        UserDefaults.standard.set(currentTime, forKey: "sessionPosition")
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: "sessionQueue"),
              let saved = try? JSONDecoder().decode([Song].self, from: data), !saved.isEmpty else { return }
        queue = saved
        index = min(UserDefaults.standard.integer(forKey: "sessionIndex"), saved.count - 1)
        currentTime = UserDefaults.standard.double(forKey: "sessionPosition")
        duration = Double(current?.duration ?? 0)
    }

    /// Restore the previous session's player item without starting playback.
    func prepareRestoredSession() {
        guard current != nil, player.currentItem == nil else { return }
        load(autoplay: false, resumeAt: currentTime)
    }

    func stop() {
        commitListening()
        player.replaceCurrentItem(with: nil)
        queue = []; index = 0; isPlaying = false
        saveSession()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Now playing / remote

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.togglePlay() }; return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.next() }; return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in MainActor.assumeIsolated { self?.previous() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            if let e = event as? MPChangePlaybackPositionCommandEvent { MainActor.assumeIsolated { self?.seek(to: e.positionTime) } }
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
            MainActor.assumeIsolated { self?.rate = e.playbackRate }
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
        else if let url = song.artwork {
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { return }
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
