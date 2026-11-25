import Foundation
import Intents
import UIKit

/// "Hey Siri, play <song / artist / album / playlist> on Koda", in the car or anywhere.
///
/// Handled in the app's own process (`KodaAppDelegate.application(_:handlerFor:)`), so playback
/// starts on the shared `MusicPlayer` without an Intents extension. Needs `INPlayMediaIntent` in
/// `INIntentsSupported`, `INSupportedMediaCategories` and the Siri capability
/// (`com.apple.developer.siri`) in signing.
nonisolated final class KodaPlayMediaHandler: NSObject, INPlayMediaIntentHandling, Sendable {
    static let shared = KodaPlayMediaHandler()

    /// What Siri asked for, as plain values that can cross to the main actor.
    struct Request: Sendable {
        var name: String?
        var artist: String?
        var album: String?
        var type: INMediaItemType
        var currentlyPlaying: Bool
        var genres: [String]
        var moods: [String]

        init(_ intent: INPlayMediaIntent) {
            let search = intent.mediaSearch
            name = search?.mediaName?.trimmed
            artist = search?.artistName?.trimmed
            album = search?.albumName?.trimmed
            type = search?.mediaType ?? .unknown
            currentlyPlaying = search?.reference == .currentlyPlaying
            genres = search?.genreNames ?? []
            moods = search?.moodNames ?? []
        }

        var query: String {
            [name, album, artist].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// One thing to play, found while resolving and played while handling.
    enum Target: Sendable {
        case resume
        case mix(DriveMix)
        case liked
        case playlist(UUID, String)
        case songs([Song], title: String, radio: Bool)
        case collection(id: String, title: String, kind: MusicKind)

        var title: String {
            switch self {
            case .resume: String(localized: "Continue listening")
            case .mix(let mix): mix.title
            case .liked: String(localized: "Liked songs")
            case .playlist(_, let name): name
            case .songs(_, let title, _): title
            case .collection(_, let title, _): title
            }
        }

        var itemType: INMediaItemType {
            switch self {
            case .resume, .songs: .song
            case .mix, .liked, .playlist: .playlist
            case .collection(_, _, let kind): kind == .album ? .album : kind == .artist ? .artist : .playlist
            }
        }
    }

    private let store = TargetStore()

    // MARK: INPlayMediaIntentHandling

    func resolveMediaItems(for intent: INPlayMediaIntent) async -> [INPlayMediaMediaItemResolutionResult] {
        let request = Request(intent)
        guard let target = await Self.find(request) else {
            return [INPlayMediaMediaItemResolutionResult.unsupported()]
        }
        let id = UUID().uuidString
        await store.put(target, for: id)
        let item = INMediaItem(identifier: id, title: target.title, type: target.itemType, artwork: nil)
        return INPlayMediaMediaItemResolutionResult.successes(with: [item])
    }

    func handle(intent: INPlayMediaIntent) async -> INPlayMediaIntentResponse {
        let request = Request(intent)
        let shuffled = intent.playShuffled ?? false
        var target: Target?
        if let id = intent.mediaItems?.first?.identifier { target = await store.take(id) }
        if target == nil { target = await Self.find(request) }
        guard let target else { return INPlayMediaIntentResponse(code: .failureUnknownMediaType, userActivity: nil) }
        let started = await Self.play(target, shuffled: shuffled)
        return INPlayMediaIntentResponse(code: started ? .success : .failure, userActivity: nil)
    }

    // MARK: Finding and playing

    @MainActor
    static func find(_ request: Request) async -> Target? {
        let library = LibraryStore.shared
        let player = MusicPlayer.shared
        if request.currentlyPlaying || (request.query.isEmpty && request.genres.isEmpty && request.moods.isEmpty) {
            // "Play Koda" / "Resume Koda": the last song, else a mix of favourites.
            if player.current != nil { return .resume }
            let mixes = MixPlanner.mixes(for: MixBuilder.inputs(), hour: Calendar.current.component(.hour, from: .now), limit: 1)
            return mixes.first.map(Target.mix)
        }
        if let name = request.name, request.artist == nil {
            let key = name.lowercased()
            if ["liked songs", "my liked songs", "liked", "favorites", "favourites", "my favorites", "my favourites"].contains(key) {
                return library.data.likedSongs.isEmpty ? nil : .liked
            }
            if let p = library.data.playlists.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                ?? library.data.playlists.first(where: { $0.name.localizedStandardContains(name) }), !p.songs.isEmpty {
                return .playlist(p.id, p.name)
            }
            if ["offline", "downloads", "my downloads", "offline mix"].contains(key) {
                return MixBuilder.inputs().offline.isEmpty ? nil : .mix(DriveMix(kind: .offline))
            }
            if ["drive mix", "driving mix", "car mix"].contains(key) { return .mix(DriveMix(kind: .drive)) }
        }
        var query = request.query
        if query.isEmpty { query = (request.genres + request.moods).joined(separator: " ") }
        guard !query.isEmpty else { return nil }

        switch request.type {
        case .album:
            if let card = try? await MusicAPI.search(query, filter: .albums).0.first {
                return .collection(id: card.id, title: card.title, kind: .album)
            }
        case .playlist:
            if let card = try? await MusicAPI.search(query, filter: .playlists).0.first {
                return .collection(id: card.id, title: card.title, kind: .playlist)
            }
        case .artist:
            if let card = try? await MusicAPI.search(query, filter: .artists).0.first {
                return .collection(id: card.id, title: card.title, kind: .artist)
            }
        default:
            break
        }
        // A song, or "play <artist>" said without a type.
        if request.name == nil, request.album == nil, let artist = request.artist,
           let card = try? await MusicAPI.search(artist, filter: .artists).0.first {
            return .collection(id: card.id, title: card.title, kind: .artist)
        }
        let songs = ((try? await MusicAPI.search(query, filter: .songs).0) ?? []).compactMap(\.song)
        guard let first = songs.first else { return nil }
        return .songs([first], title: first.title, radio: true)
    }

    @MainActor
    static func play(_ target: Target, shuffled: Bool) async -> Bool {
        let player = MusicPlayer.shared
        let library = LibraryStore.shared
        func start(_ songs: [Song], radio: Bool = false) -> Bool {
            guard !songs.isEmpty else { return false }
            player.play(songs, startAt: shuffled ? Int.random(in: 0..<songs.count) : 0, shuffled: shuffled, radio: radio)
            return true
        }
        switch target {
        case .resume:
            player.play()
            return player.current != nil
        case .mix(let mix):
            return start(await MixBuilder.build(mix))
        case .liked:
            return start(library.data.likedSongs.map(\.song))
        case .playlist(let id, _):
            return start(library.playlist(id)?.songs ?? [])
        case .songs(let songs, _, let radio):
            return start(songs, radio: radio)
        case .collection(let id, _, let kind):
            if kind == .artist {
                let songs = (try? await MusicAPI.artist(id))?.topSongs ?? []
                guard !songs.isEmpty else { return false }
                // An artist plays shuffled by default, then continues with their radio.
                player.play(songs, startAt: Int.random(in: 0..<songs.count), shuffled: true)
                return true
            }
            return start((try? await MusicAPI.collection(id))?.songs ?? [])
        }
    }
}

/// Targets found by `resolveMediaItems`, picked up again by `handle` through the item's identifier.
private actor TargetStore {
    private var targets: [String: KodaPlayMediaHandler.Target] = [:]

    func put(_ target: KodaPlayMediaHandler.Target, for id: String) {
        if targets.count > 20 { targets.removeAll() }
        targets[id] = target
    }

    func take(_ id: String) -> KodaPlayMediaHandler.Target? { targets.removeValue(forKey: id) }
}

private extension String {
    nonisolated var trimmed: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Hands Siri's play requests to `KodaPlayMediaHandler`.
final class KodaAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Google Cast has to be set up at launch; it doesn't look for devices until the Cast button is tapped.
        CastManager.setUp()
        return true
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? KodaPlayMediaHandler.shared : nil
    }

    /// Video downloads finish in a background URLSession; iOS wakes the app with its events.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == VideoDownloadManager.sessionIdentifier else { completionHandler(); return }
        VideoDownloadManager.shared.backgroundCompletion = completionHandler
    }
}
