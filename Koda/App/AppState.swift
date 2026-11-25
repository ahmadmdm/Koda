import AppIntents
import SwiftUI
import Observation

enum AppTab: Hashable { case home, library, subscriptions, settings, search }

@MainActor
@Observable
final class AppState {
    var mode: AppMode = AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "music") ?? .music {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "appMode") }
    }
    var tab: AppTab = .home
    var paths: [AppTab: NavigationPath] = [.home: NavigationPath(), .library: NavigationPath(), .subscriptions: NavigationPath(), .settings: NavigationPath(), .search: NavigationPath()]
    var showPlayer = false
    var addToPlaylist: [Song]?
    var shorts: ShortsLaunch?
    var toast: String?
    /// A search asked for from outside the view, for example by Siri; the search tab runs it.
    var searchRequest: String?

    /// The app's state, for App Intents running in the app's process.
    private(set) static weak var current: AppState?

    init() {
        Self.current = self
        KodaShortcuts.updateAppShortcutParameters()
    }

    func path(_ tab: AppTab) -> Binding<NavigationPath> {
        Binding(get: { self.paths[tab] ?? NavigationPath() }, set: { self.paths[tab] = $0 })
    }

    func navigate(_ route: Route) {
        showPlayer = false
        VideoPlayerModel.shared.isPresented = false
        if tab == .settings { tab = .home }
        paths[tab, default: NavigationPath()].append(route)
    }

    func search(_ text: String) {
        showPlayer = false
        VideoPlayerModel.shared.isPresented = false
        mode = .music
        tab = .search
        paths[.search] = NavigationPath()
        searchRequest = text
    }

    func showToast(_ key: String.LocalizationValue) {
        let text = String(localized: key)
        toast = text
        Task { try? await Task.sleep(for: .seconds(2)); if toast == text { toast = nil } }
    }

    /// Opens shared YouTube / YouTube Music links (watch, youtu.be, shorts, playlist, channel).
    func open(url: URL) {
        if url.scheme == "koda", url.host == "nowplaying" {
            if MusicPlayer.shared.current != nil { mode = .music; showPlayer = true }
            return
        }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = Dictionary((comps?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        let host = url.host ?? ""
        var parts = url.pathComponents.filter { $0 != "/" }
        if url.scheme == "koda", let first = host.isEmpty ? nil : host { parts.insert(first, at: 0) }
        let isMusic = host.contains("music.youtube.com")
        if parts.first == "shorts", !isMusic, let id = parts.dropFirst().first {
            showPlayer = false
            VideoPlayerModel.shared.isPresented = false
            shorts = ShortsLaunch(items: [ShortItem(id: id)])
            return
        }
        if let v = query["v"] ?? (host.contains("youtu.be") ? parts.first : nil) ?? (parts.first == "shorts" || parts.first == "live" ? parts.dropFirst().first : nil) {
            if isMusic || mode == .music {
                Task {
                    let info = try? await InnerTube.shared.player(videoId: v)
                    let song = Song(id: v, title: info?.title ?? "Song", artist: info?.author ?? "",
                                    duration: info.map { Int($0.duration) }, thumbnail: info?.thumbnail)
                    MusicPlayer.shared.play([song], radio: true)
                    showPlayer = true
                }
            } else {
                VideoPlayerModel.shared.open(Video(id: v, title: "", channel: ""))
            }
        } else if let list = query["list"] {
            if isMusic { mode = .music; navigate(.playlist(list)) } else { navigate(.videoPlaylist(list, "Playlist")) }
        } else if parts.first == "channel", let id = parts.dropFirst().first {
            if isMusic { navigate(.artist(id)) } else { mode = .video; navigate(.channel(id)) }
        } else if parts.first == "browse", let id = parts.dropFirst().first {
            navigate(id.hasPrefix("MPRE") ? .album(id) : .artist(id))
        }
    }
}

enum Palette: String, CaseIterable, Identifiable {
    case violet, emerald, sunset, ocean, crimson, blossom, solar, midnight, artwork
    var id: String { rawValue }
    var title: String { self == .artwork ? String(localized: "From Artwork") : String(localized: String.LocalizationValue(rawValue.capitalized)) }
    var color: Color {
        switch self {
        case .violet, .artwork: Color(red: 0.40, green: 0.31, blue: 0.64)
        case .emerald: Color(red: 0.11, green: 0.55, blue: 0.36)
        case .sunset: Color(red: 0.93, green: 0.45, blue: 0.24)
        case .ocean: Color(red: 0.12, green: 0.47, blue: 0.80)
        case .crimson: Color(red: 0.78, green: 0.16, blue: 0.23)
        case .blossom: Color(red: 0.89, green: 0.38, blue: 0.62)
        case .solar: Color(red: 0.86, green: 0.65, blue: 0.10)
        case .midnight: Color(red: 0.25, green: 0.27, blue: 0.55)
        }
    }
}

enum PlayerStyle: String, CaseIterable, Identifiable {
    case classic, hero, editorial, canvas, bento, dial
    var id: String { rawValue }
    var title: String { String(localized: String.LocalizationValue(rawValue.capitalized)) }
    var icon: String {
        switch self {
        case .classic: "rectangle.portrait"
        case .hero: "photo.fill"
        case .editorial: "textformat.size.larger"
        case .canvas: "paintpalette.fill"
        case .bento: "square.grid.2x2.fill"
        case .dial: "dial.medium.fill"
        }
    }
}
