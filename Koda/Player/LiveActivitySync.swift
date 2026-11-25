import ActivityKit
import Foundation

/// Starts, updates and ends the music Live Activity. Called from `WidgetSync`, so it follows every
/// song change, play, pause, seek and stop. Progress runs on the clock in the widget, so the activity
/// is only updated when something it shows changes.
@MainActor
enum LiveActivitySync {
    static let enabledKey = "liveActivity"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    private typealias State = NowPlayingActivityAttributes.ContentState
    private static var activity: Activity<NowPlayingActivityAttributes>?
    private static var lastState: State?
    private static var artworkSongId: String?
    private static var adopted = false

    static func update(_ player: MusicPlayer) {
        adoptExisting()
        guard isEnabled, ActivityAuthorizationInfo().areActivitiesEnabled, let song = player.current else {
            end()
            return
        }
        let state = State(songId: song.id, title: song.title, artist: song.artist, isPlaying: player.isPlaying,
                          elapsed: player.currentTime, duration: player.duration, capturedAt: .now,
                          artworkSongId: artworkSongId)
        let previous = lastState
        if let activity, activity.activityState == .active || activity.activityState == .stale {
            guard changed(from: previous, to: state) else { return }
            lastState = state
            let id = activity.id
            Task { await send(id, ActivityContent(state: state, staleDate: nil)) }
            return
        }
        activity = nil
        lastState = state
        // Start when music starts or the song changes, not again right after the user dismissed it.
        guard state.isPlaying, previous == nil || previous?.songId != state.songId || previous?.isPlaying == false else { return }
        activity = try? Activity.request(attributes: NowPlayingActivityAttributes(),
                                         content: ActivityContent(state: state, staleDate: nil), pushType: nil)
    }

    /// `WidgetSync` wrote the App Group artwork for this song.
    static func artworkSaved(songId: String) {
        artworkSongId = songId
        update(MusicPlayer.shared)
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
            || Int(old.duration) != Int(new.duration) { return true }
        // A seek: the clock-based start no longer matches (or, while paused, the position moved).
        return new.isPlaying
            ? abs(old.startDate.timeIntervalSince(new.startDate)) > 1.5
            : abs(old.elapsed - new.elapsed) > 1
    }
}
