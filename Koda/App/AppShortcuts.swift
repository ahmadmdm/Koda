import AppIntents
import Foundation

// Siri and Shortcuts. The intents that play are `AudioPlaybackIntent`s, so the system runs them in
// the app's process and lets them start audio from the background.

// MARK: Playlists

nonisolated struct PlaylistEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static let defaultQuery = PlaylistEntityQuery()

    var id: UUID
    var name: String
    var songCount: Int

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(songCount) songs")
    }

    init(_ playlist: LocalPlaylist) {
        id = playlist.id
        name = playlist.name
        songCount = playlist.songs.count
    }
}

nonisolated struct PlaylistEntityQuery: EntityStringQuery {
    init() {}

    func entities(for identifiers: [UUID]) async throws -> [PlaylistEntity] {
        await MainActor.run {
            identifiers.compactMap { LibraryStore.shared.playlist($0).map(PlaylistEntity.init) }
        }
    }

    func entities(matching string: String) async throws -> [PlaylistEntity] {
        await MainActor.run {
            LibraryStore.shared.data.playlists
                .filter { $0.name.localizedStandardContains(string) }
                .map(PlaylistEntity.init)
        }
    }

    func suggestedEntities() async throws -> [PlaylistEntity] {
        await MainActor.run { LibraryStore.shared.data.playlists.map(PlaylistEntity.init) }
    }
}

// MARK: Intents

nonisolated enum KodaIntentError: Error, CustomLocalizedStringResourceConvertible {
    case noLikedSongs, emptyLibrary, emptyPlaylist, nothingToStartFrom

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLikedSongs: "You haven't liked any songs in Koda yet."
        case .emptyLibrary: "Your Koda library is empty."
        case .emptyPlaylist: "That playlist has no songs."
        case .nothingToStartFrom: "Play a song in Koda first, then start a radio from it."
        }
    }
}

struct PlayLikedSongsIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Liked Songs"
    static let description = IntentDescription("Plays the songs you liked in Koda.")

    @Parameter(title: "Shuffle", default: false) var shuffle: Bool

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        let songs = LibraryStore.shared.data.likedSongs.map(\.song)
        guard !songs.isEmpty else { throw KodaIntentError.noLikedSongs }
        MusicPlayer.shared.play(songs, startAt: shuffle ? Int.random(in: songs.indices) : 0, shuffled: shuffle)
        return .result()
    }
}

struct ShuffleLibraryIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Shuffle Library"
    static let description = IntentDescription("Shuffles your liked songs, playlists and downloads in Koda.")

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        let data = LibraryStore.shared.data
        var seen = Set<String>()
        let songs = (data.likedSongs.map(\.song) + data.playlists.flatMap(\.songs) + data.downloads.map(\.song))
            .filter { seen.insert($0.id).inserted }
        guard !songs.isEmpty else { throw KodaIntentError.emptyLibrary }
        MusicPlayer.shared.play(songs, startAt: Int.random(in: songs.indices), shuffled: true)
        return .result()
    }
}

struct PlayPlaylistIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription("Plays one of your Koda playlists.")

    @Parameter(title: "Playlist") var playlist: PlaylistEntity
    @Parameter(title: "Shuffle", default: false) var shuffle: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$playlist)") { \.$shuffle }
    }

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        guard let songs = LibraryStore.shared.playlist(playlist.id)?.songs, !songs.isEmpty else {
            throw KodaIntentError.emptyPlaylist
        }
        MusicPlayer.shared.play(songs, startAt: shuffle ? Int.random(in: songs.indices) : 0, shuffled: shuffle)
        return .result()
    }
}

struct StartRadioIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Start Radio"
    static let description = IntentDescription("Starts a radio from the song playing, or the last one you played.")

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        let library = LibraryStore.shared
        guard let seed = MusicPlayer.shared.current ?? library.data.plays.last?.song ?? library.data.likedSongs.first?.song else {
            throw KodaIntentError.nothingToStartFrom
        }
        MusicPlayer.shared.startRadio(from: seed)
        return .result()
    }
}

struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description = IntentDescription("Tells you the song playing in Koda.")

    init() {}

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let player = MusicPlayer.shared
        guard let song = player.current else { return .result(dialog: "Nothing is playing in Koda.") }
        if player.isPlaying {
            return .result(dialog: "Playing \(song.title) by \(song.artist).")
        }
        return .result(dialog: "\(song.title) by \(song.artist) is paused.")
    }
}

struct SearchKodaIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Koda"
    static let description = IntentDescription("Opens Koda's search with your words.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Search", requestValueDialog: "What do you want to search for?") var text: String

    static var parameterSummary: some ParameterSummary { Summary("Search Koda for \(\.$text)") }

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .result() }
        AppState.current?.search(query)
        return .result()
    }
}

// MARK: Shortcuts

struct KodaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayLikedSongsIntent(), phrases: [
            "Play my liked songs in \(.applicationName)",
            "Play my favorites in \(.applicationName)",
        ], shortTitle: "Liked Songs", systemImageName: "heart.fill")
        AppShortcut(intent: ShuffleLibraryIntent(), phrases: [
            "Shuffle my library in \(.applicationName)",
            "Shuffle my music in \(.applicationName)",
        ], shortTitle: "Shuffle Library", systemImageName: "shuffle")
        AppShortcut(intent: PlayPlaylistIntent(), phrases: [
            "Play \(\.$playlist) in \(.applicationName)",
            "Play my \(\.$playlist) playlist in \(.applicationName)",
            "Play a playlist in \(.applicationName)",
        ], shortTitle: "Play Playlist", systemImageName: "music.note.list")
        AppShortcut(intent: SearchKodaIntent(), phrases: [
            "Search \(.applicationName)",
            "Search in \(.applicationName)",
        ], shortTitle: "Search", systemImageName: "magnifyingglass")
        AppShortcut(intent: StartRadioIntent(), phrases: [
            "Start radio in \(.applicationName)",
            "Start a radio in \(.applicationName)",
        ], shortTitle: "Start Radio", systemImageName: "dot.radiowaves.left.and.right")
        AppShortcut(intent: WhatsPlayingIntent(), phrases: [
            "What's playing in \(.applicationName)",
            "What song is this in \(.applicationName)",
        ], shortTitle: "What's Playing", systemImageName: "waveform")
    }
}
