import Foundation
import GoogleCast
import Observation
import os
import UIKit

/// One song or video as the receiver gets it.
struct CastItem {
    var id: String
    var url: URL
    var contentType: String
    var title: String
    var subtitle: String
    var album: String?
    var artwork: URL?
    var duration: Double
    var isVideo = false
    var isLive = false
    var hlsSegmentFormat: GCKHLSSegmentFormat = .undefined
    var hlsVideoSegmentFormat: GCKHLSVideoSegmentFormat = .undefined
}

/// What the receiver reports, reduced to what the players need.
struct CastStatus {
    enum State { case idle, playing, paused, buffering }
    var state: State
    var idleReason: GCKMediaPlayerIdleReason
    /// The `contentID` (song or video id) of the item playing, if any.
    var contentID: String?
    var position: Double
    var duration: Double
    /// The ids of the items queued after the current one.
    var upcoming: [String]
}

/// Google Cast: the session with a Chromecast (or a TV with Cast built in) running the Default Media
/// Receiver, and the media on it. `MusicPlayer` and `VideoPlayerModel` hand their media here while a
/// session is up, and follow the receiver's status; when the session ends, they continue on the iPhone
/// where the receiver was.
@MainActor
@Observable
final class CastManager: NSObject {
    static let shared = CastManager()

    enum Media: Equatable { case none, music, video(String) }

    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var deviceName: String?
    /// What this app last loaded on the receiver.
    private(set) var media: Media = .none

    @ObservationIgnored private(set) var lastStatus: CastStatus?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var proxyHost: String?
    @ObservationIgnored private var proxyPort: UInt16?
    /// A session ended by the listener (Stop Casting) rather than lost.
    @ObservationIgnored private var endingOnPurpose = false

    private var context: GCKCastContext? { GCKCastContext.isSharedInstanceInitialized() ? GCKCastContext.sharedInstance() : nil }
    private var remote: GCKRemoteMediaClient? { context?.sessionManager.currentCastSession?.remoteMediaClient }

    var isCastingMusic: Bool { isConnected && media == .music }

    func isCastingVideo(_ id: String?) -> Bool { isConnected && id != nil && media == .video(id!) }

    // MARK: Setup

    /// Called once at launch. Discovery doesn't start until the Cast button is first tapped (the SDK's
    /// default since 4.5.3), so iOS asks for local network access then, not at launch.
    static func setUp() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.startDiscoveryAfterFirstTapOnCastButton = true
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        // Keep the session while the app plays in the background (it has the audio background mode),
        // so the lock screen controls and queue advancing keep working.
        options.suspendSessionsWhenBackgrounded = false
        // "Stop Casting" stops the receiver too: playback continues on the iPhone instead.
        options.stopReceiverApplicationWhenEndingSession = true
        options.disableAnalyticsLogging = true
        GCKCastContext.setSharedInstanceWith(options)
        let context = GCKCastContext.sharedInstance()
        context.useDefaultExpandedMediaControls = false
        context.sessionManager.add(shared)
    }

    // MARK: Dialog and session

    /// The device picker, for places that can't host a `GCKUICastButton` (a menu).
    func presentDialog() {
        guard let context else { return }
        // Asking here is the user's choice to cast: start looking (iOS asks for local network access
        // the first time), then show what is found.
        if !context.discoveryManager.discoveryActive { context.discoveryManager.startDiscovery() }
        context.presentCastDialog()
    }

    func endSession() {
        endingOnPurpose = true
        context?.sessionManager.endSessionAndStopCasting(true)
    }

    private func sessionStarted(_ session: GCKSession) {
        isConnecting = false
        isConnected = true
        deviceName = session.device.friendlyName ?? String(localized: "Cast device")
        media = .none
        remote?.add(self)
        startTicking()
        AppState.current?.showToast("Casting to \(deviceName ?? "")")
        // Whatever is playing (or paused) moves to the receiver.
        if NowPlayingOwner.isVideo, VideoPlayerModel.shared.current != nil {
            VideoPlayerModel.shared.castCurrent()
        } else if MusicPlayer.shared.current != nil {
            MusicPlayer.shared.castCurrent()
        }
    }

    private func sessionEnded(error: Error?) {
        let ended = media
        let name = deviceName ?? ""
        let status = lastStatus
        let position = status?.position ?? 0
        let wasPlaying = status.map { $0.state == .playing || $0.state == .buffering } ?? false
        isConnected = false
        isConnecting = false
        media = .none
        lastStatus = nil
        tickTask?.cancel()
        tickTask = nil
        CastProxyServer.shared.stop()
        proxyHost = nil
        proxyPort = nil
        if let error, !endingOnPurpose, (error as NSError).code != GCKErrorCode.cancelled.rawValue {
            castLog.error("session ended: \(String(describing: error), privacy: .public)")
            AppState.current?.showToast("Lost the connection to \(name). Playing on this iPhone.")
        }
        endingOnPurpose = false
        deviceName = nil
        switch ended {
        case .music: MusicPlayer.shared.castEnded(at: position, wasPlaying: wasPlaying)
        case .video(let id): VideoPlayerModel.shared.castEnded(id: id, at: position, wasPlaying: wasPlaying)
        case .none: break
        }
    }

    // MARK: Loading

    /// Loads songs on the receiver: the first plays from `position`, the rest are queued after it so
    /// the receiver goes on by itself even while the iPhone sleeps.
    func loadMusic(_ items: [CastItem], position: Double, autoplay: Bool, repeatOne: Bool, rate: Float) {
        guard let remote, let first = items.first else { return }
        media = .music
        lastStatus = CastStatus(state: autoplay ? .buffering : .paused, idleReason: .none, contentID: first.id,
                                position: position, duration: first.duration, upcoming: items.dropFirst().map(\.id))
        let queue = GCKMediaQueueDataBuilder(queueType: .playlist)
        queue.items = items.map(Self.queueItem)
        queue.startIndex = 0
        queue.startTime = position
        queue.repeatMode = repeatOne ? .single : .off
        let request = GCKMediaLoadRequestDataBuilder()
        request.queueData = queue.build()
        request.autoplay = NSNumber(value: autoplay)
        request.startTime = position
        request.playbackRate = rate
        track(remote.loadMedia(with: request.build()), failure: "\(first.title)")
    }

    func loadVideo(_ item: CastItem, position: Double, autoplay: Bool, rate: Float) {
        guard let remote else { return }
        media = .video(item.id)
        lastStatus = CastStatus(state: autoplay ? .buffering : .paused, idleReason: .none, contentID: item.id,
                                position: position, duration: item.duration, upcoming: [])
        let request = GCKMediaLoadRequestDataBuilder()
        request.mediaInformation = Self.mediaInformation(item)
        request.autoplay = NSNumber(value: autoplay)
        request.startTime = item.isLive ? 0 : position
        request.playbackRate = rate
        track(remote.loadMedia(with: request.build()), failure: item.title)
    }

    /// Replaces what is queued after the current song.
    func replaceUpcoming(_ items: [CastItem]) {
        guard let remote, let status = remote.mediaStatus else { return }
        let currentID = status.currentItemID
        var after: [NSNumber] = []
        var seenCurrent = false
        for i in 0..<status.queueItemCount {
            guard let item = status.queueItem(at: i) else { continue }
            if seenCurrent { after.append(NSNumber(value: item.itemID)) }
            if item.itemID == currentID { seenCurrent = true }
        }
        if !after.isEmpty { remote.queueRemoveItems(withIDs: after) }
        if !items.isEmpty { remote.queueInsert(items.map(Self.queueItem), beforeItemWithID: kGCKMediaQueueInvalidItemID) }
        lastStatus?.upcoming = items.map(\.id)
    }

    /// Plays a song already queued on the receiver; false when it isn't there.
    func jump(to contentID: String) -> Bool {
        guard let remote, let status = remote.mediaStatus else { return false }
        for i in 0..<status.queueItemCount {
            if let item = status.queueItem(at: i), item.mediaInformation.contentID == contentID {
                remote.queueJumpToItem(withID: item.itemID)
                lastStatus?.contentID = contentID
                lastStatus?.position = 0
                return true
            }
        }
        return false
    }

    func play() { remote?.play(); lastStatus?.state = .playing }
    func pause() { remote?.pause(); lastStatus?.state = .paused }
    func stopMedia() { remote?.stop(); media = .none; lastStatus = nil }

    func seek(to seconds: Double) {
        let options = GCKMediaSeekOptions()
        options.interval = max(0, seconds)
        options.resumeState = .unchanged
        remote?.seek(with: options)
        lastStatus?.position = seconds
    }

    func setRate(_ rate: Float) { remote?.setPlaybackRate(rate) }

    func setRepeatOne(_ on: Bool) { remote?.queueSetRepeatMode(on ? .single : .off) }

    /// The receiver's position, extrapolated between status messages.
    var position: Double {
        guard let remote, remote.mediaStatus != nil else { return lastStatus?.position ?? 0 }
        let p = remote.approximateStreamPosition()
        return p.isFinite ? max(0, p) : 0
    }

    // MARK: Proxy

    /// The proxy's address on the network, started if needed.
    func proxyEndpoint() async throws -> (host: String, port: UInt16) {
        if let proxyHost, let proxyPort { return (proxyHost, proxyPort) }
        guard let host = CastProxyServer.lanAddress() else { throw CastError.noNetwork }
        let port = try await CastProxyServer.shared.start()
        proxyHost = host
        proxyPort = port
        return (host, port)
    }

    enum CastError: LocalizedError {
        case noNetwork
        var errorDescription: String? { String(localized: "Connect to the same Wi-Fi as the Cast device.") }
    }

    // MARK: Building media

    private static func mediaInformation(_ item: CastItem) -> GCKMediaInformation {
        let metadata = GCKMediaMetadata(metadataType: item.isVideo ? .generic : .musicTrack)
        metadata.setString(item.title, forKey: kGCKMetadataKeyTitle)
        if item.isVideo {
            metadata.setString(item.subtitle, forKey: kGCKMetadataKeySubtitle)
        } else {
            metadata.setString(item.subtitle, forKey: kGCKMetadataKeyArtist)
            if let album = item.album { metadata.setString(album, forKey: kGCKMetadataKeyAlbumTitle) }
        }
        if let artwork = item.artwork {
            metadata.addImage(GCKImage(url: artwork, width: item.isVideo ? 1280 : 544, height: item.isVideo ? 720 : 544))
        }
        let builder = GCKMediaInformationBuilder(contentURL: item.url)
        builder.contentID = item.id
        builder.contentType = item.contentType
        builder.streamType = item.isLive ? .live : .buffered
        builder.metadata = metadata
        if item.duration > 0, !item.isLive { builder.streamDuration = item.duration }
        builder.hlsSegmentFormat = item.hlsSegmentFormat
        builder.hlsVideoSegmentFormat = item.hlsVideoSegmentFormat
        return builder.build()
    }

    private static func queueItem(_ item: CastItem) -> GCKMediaQueueItem {
        let builder = GCKMediaQueueItemBuilder()
        builder.mediaInformation = mediaInformation(item)
        builder.autoplay = true
        // Fetch the next song's start while this one finishes, for a gapless change.
        builder.preloadTime = 15
        return builder.build()
    }

    // MARK: Requests and status

    @ObservationIgnored private var failures: [ObjectIdentifier: String] = [:]

    private func track(_ request: GCKRequest, failure title: String) {
        failures[ObjectIdentifier(request)] = title
        request.delegate = self
    }

    private func statusChanged(_ status: GCKMediaStatus?) {
        guard let status else { return }
        let state: CastStatus.State = switch status.playerState {
        case .playing: .playing
        case .paused: .paused
        case .buffering, .loading: .buffering
        default: .idle
        }
        var upcoming: [String] = []
        var seenCurrent = false
        for i in 0..<status.queueItemCount {
            guard let item = status.queueItem(at: i) else { continue }
            if seenCurrent, let id = item.mediaInformation.contentID { upcoming.append(id) }
            if item.itemID == status.currentItemID { seenCurrent = true }
        }
        let info = status.mediaInformation ?? status.currentQueueItem?.mediaInformation
        let duration = info?.streamDuration ?? 0
        let reduced = CastStatus(state: state, idleReason: status.idleReason, contentID: info?.contentID,
                                 position: status.streamPosition.isFinite ? status.streamPosition : 0,
                                 duration: duration.isFinite ? duration : 0,
                                 upcoming: status.queueItemCount > 0 ? upcoming : (lastStatus?.upcoming ?? []))
        lastStatus = reduced
        if state == .idle, status.idleReason == .error {
            AppState.current?.showToast("\(deviceName ?? String(localized: "The Cast device")) couldn't play this.")
        }
        switch media {
        case .music: MusicPlayer.shared.castStatusChanged(reduced)
        case .video(let id): VideoPlayerModel.shared.castStatusChanged(reduced, id: id)
        case .none: break
        }
    }

    /// The receiver only reports changes: the position in between comes from the SDK's extrapolation.
    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isConnected else { continue }
                let position = self.position
                switch self.media {
                case .music: MusicPlayer.shared.castTick(position)
                case .video(let id): VideoPlayerModel.shared.castTick(position, id: id)
                case .none: break
                }
            }
        }
    }
}

// The SDK calls its listeners and delegates on the main thread.

extension CastManager: @preconcurrency GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, willStart session: GCKSession) {
        isConnecting = true
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        sessionStarted(session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        // Back after the app was suspended or relaunched: the receiver may still play what was cast.
        isConnecting = false
        isConnected = true
        deviceName = session.device.friendlyName ?? String(localized: "Cast device")
        remote?.add(self)
        startTicking()
        if let id = remote?.mediaStatus?.mediaInformation?.contentID {
            if id == MusicPlayer.shared.current?.id || MusicPlayer.shared.upNext.contains(where: { $0.id == id }) { media = .music }
            else if id == VideoPlayerModel.shared.current?.id { media = .video(id) }
        }
        statusChanged(remote?.mediaStatus)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, willEnd session: GCKSession) {
        // The last position, before the session (and its status) goes.
        if lastStatus != nil { lastStatus?.position = position }
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        sessionEnded(error: error)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        isConnecting = false
        castLog.error("session failed to start: \(String(describing: error), privacy: .public)")
        AppState.current?.showToast("Couldn't connect to \(session.device.friendlyName ?? String(localized: "the Cast device")).")
    }
}

extension CastManager: @preconcurrency GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        statusChanged(mediaStatus)
    }
}

extension CastManager: @preconcurrency GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        failures[ObjectIdentifier(request)] = nil
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        let title = failures.removeValue(forKey: ObjectIdentifier(request)) ?? ""
        castLog.error("load failed: \(String(describing: error), privacy: .public)")
        // A load replaced by the next one isn't a failure.
        guard error.code != GCKErrorCode.replaced.rawValue, error.code != GCKErrorCode.cancelled.rawValue else { return }
        AppState.current?.showToast("\(deviceName ?? String(localized: "The Cast device")) couldn't play \(title).")
        switch media {
        case .music: MusicPlayer.shared.castLoadFailed()
        case .video(let id): VideoPlayerModel.shared.castLoadFailed(id: id)
        case .none: break
        }
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        failures[ObjectIdentifier(request)] = nil
    }
}

extension CastManager: @preconcurrency GCKUICastButtonDelegate {
    /// The first tap ever: skip the SDK's explanation screen and start looking right away, which is
    /// when iOS asks for local network access (with Koda's own reason from Info.plist).
    func castButtonDidTap(toPresentLocalNetworkAccessPermissionDialog castButton: GCKUICastButton) {
        presentDialog()
    }

    func castButtonDidTap(_ castButton: GCKUICastButton, toPresentDialogFor castState: GCKCastState) {
        if castState == .noDevicesAvailable {
            AppState.current?.showToast("No Cast devices found. Check that this iPhone and the Cast device are on the same Wi-Fi.")
        }
        presentDialog()
    }
}
