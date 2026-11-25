import AppIntents
import Foundation

enum PlaybackCommand: Sendable { case toggle, next, previous, like }

/// The app registers what each command does. The intents below are `AudioPlaybackIntent`s, which
/// the system runs in the app's process, so the handler is there even when a widget triggers them.
@MainActor
enum PlaybackCommandCenter {
    static var handler: ((PlaybackCommand) -> Void)?
}

struct TogglePlaybackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses the current song in Koda.")
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        PlaybackCommandCenter.handler?(.toggle)
        return .result()
    }
}

struct NextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Song"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        PlaybackCommandCenter.handler?(.next)
        return .result()
    }
}

struct PreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Song"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        PlaybackCommandCenter.handler?(.previous)
        return .result()
    }
}

struct ToggleLikeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Like Song"
    init() {}
    @MainActor func perform() async throws -> some IntentResult {
        PlaybackCommandCenter.handler?(.like)
        return .result()
    }
}
