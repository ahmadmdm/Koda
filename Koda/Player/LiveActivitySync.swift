import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the music Live Activity. Called from `WidgetSync`, so it follows every
/// song change, play, pause, seek and stop. Progress runs on the clock in the widget, so the activity
/// is only updated when something it shows changes. While a video owns Now Playing, the same activity
/// shows the video instead, driven by `VideoPlayerModel` through `updateVideo`.
@MainActor
enum LiveActivitySync {
    static let enabledKey = "liveActivity"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }

    private typealias State = NowPlayingActivityAttributes.ContentState
    private static var activity: Activity<NowPlayingActivityAttributes>?
    private static var lastState: State?
    private static var artworkSongId: String?
    private static var videoArtworkId: String?
    private static var adopted = false

    static func update(_ player: MusicPlayer) {
        adoptExisting()
        // The video player drives the activity while it owns Now Playing.
        guard !NowPlayingOwner.isVideo else { return }
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled, let song = player.current else {
            end()
            return
        }
        let state = State(songId: song.id, title: song.title, artist: song.artist, isPlaying: player.isPlaying,
                          elapsed: player.currentTime, duration: player.duration, capturedAt: .now,
                          artworkSongId: artworkSongId)
        apply(state)
    }

    /// The playing video, while it owns Now Playing.
    static func updateVideo(_ model: VideoPlayerModel) {
        adoptExisting()
        guard NowPlayingOwner.isVideo else { return }
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled, let video = model.current else {
            end()
            return
        }
        var state = State(songId: video.id, title: model.nowPlayingTitle, artist: model.nowPlayingChannel,
                          isPlaying: model.isPlaying, elapsed: model.elapsed, duration: model.duration,
                          capturedAt: .now, artworkSongId: videoArtworkId)
        state.isVideo = true
        state.hasNext = model.hasNext
        apply(state)
    }

    private static func apply(_ state: State) {
        let previous = lastState
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            guard changed(from: previous, to: state) else { return }
            lastState = state
            let id = activity.id
            // A pause from a widget or CarPlay leaves the app without audio, so iOS may suspend it
            // before the update reaches the system: keep it awake until the update is sent.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Live Activity")
            Task {
                await send(id, content(state))
                UIApplication.shared.endBackgroundTask(background)
            }
            return
        }
        activity = nil
        lastState = state
        // Start when music starts or the song changes, not again right after the user dismissed it.
        guard state.isPlaying, previous == nil || previous?.songId != state.songId || previous?.isPlaying == false else { return }
        activity = try? Activity.request(attributes: NowPlayingActivityAttributes(),
                                         content: content(state), pushType: nil)
    }

    /// While playing, the activity goes stale when the song should have ended: if the app was closed
    /// meanwhile, nothing else would tell the system it stopped.
    private static func content(_ state: State) -> ActivityContent<State> {
        // A live stream has no end to go stale at.
        ActivityContent(state: state, staleDate: state.isPlaying && state.duration > 0 ? state.endDate : nil)
    }

    /// `WidgetSync` wrote the App Group artwork for this song.
    static func artworkSaved(songId: String) {
        artworkSongId = songId
        update(MusicPlayer.shared)
    }

    /// Writes the video's thumbnail for the activity: a small square JPEG cut from its centre (the
    /// Dynamic Island shows a blank for large images).
    static func saveVideoArtwork(_ image: UIImage, videoId: String) {
        guard videoId != videoArtworkId, let url = NowPlayingSnapshot.videoArtworkURL else { return }
        let content = CGRect(origin: .zero, size: image.size)
        let side: CGFloat = 200
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let square = renderer.image { _ in
            let scale = max(side / content.width, side / content.height)
            let origin = CGPoint(x: side / 2 - content.midX * scale, y: side / 2 - content.midY * scale)
            image.draw(in: CGRect(origin: origin, size: CGSize(width: image.size.width * scale, height: image.size.height * scale)))
        }
        guard (try? square.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)) != nil else { return }
        videoArtworkId = videoId
        updateVideo(.shared)
    }

    static func end() {
        let ending = activity.map { [$0] } ?? Activity<NowPlayingActivityAttributes>.activities
        let final = lastState.map { ActivityContent(state: $0, staleDate: nil) }
        activity = nil
        lastState = nil
        for id in ending.map(\.id) {
            Task { await send(id, final, ending: true) }
        }
    }

    /// After a relaunch, keep the activity a previous run left and end any extras.
    private static func adoptExisting() {
        guard !adopted else { return }
        adopted = true
        let existing = Activity<NowPlayingActivityAttributes>.activities
        activity = existing.first
        lastState = existing.first?.content.state
        for id in existing.dropFirst().map(\.id) {
            Task { await send(id, nil, ending: true) }
        }
    }

    /// Activities aren't Sendable, so look the activity up again off the main actor.
    nonisolated private static func send(_ id: String, _ content: ActivityContent<State>?, ending: Bool = false) async {
        for activity in Activity<NowPlayingActivityAttributes>.activities where activity.id == id {
            if ending {
                await activity.end(content, dismissalPolicy: .immediate)
            } else if let content {
                await activity.update(content)
            }
        }
    }

    private static func changed(from old: State?, to new: State) -> Bool {
        guard let old else { return true }
        if old.songId != new.songId || old.title != new.title || old.artist != new.artist
            || old.isPlaying != new.isPlaying || old.artworkSongId != new.artworkSongId
            || old.isVideo != new.isVideo || old.hasNext != new.hasNext
            || Int(old.duration) != Int(new.duration) { return true }
        // A seek: the clock-based start no longer matches (or, while paused, the position moved).
        return new.isPlaying
            ? abs(old.startDate.timeIntervalSince(new.startDate)) > 1.5
            : abs(old.elapsed - new.elapsed) > 1
    }
}
