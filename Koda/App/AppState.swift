import AppIntents
import SwiftUI
import Observation

enum AppTab: Hashable { case home, library, subscriptions, settings, search }

@MainActor
@Observable
final class AppState {
    var mode: AppMode = AppMode(rawValue: UserDefaults.standard.string(forKey: "appMode") ?? "music") ?? .music {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appMode")
            // Music mode has no Subscriptions tab.
            if mode == .music && tab == .subscriptions { tab = .home }
        }
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
        shorts = nil
        VideoPlayerModel.shared.isPresented = false
        if tab == .settings || (tab == .subscriptions && mode == .music) { tab = .home }
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
        // Longer messages (errors) stay long enough to read.
        Task { try? await Task.sleep(for: .seconds(text.count > 40 ? 4 : 2)); if toast == text { toast = nil } }
    }

    /// Closes the Shorts pager and the watch page; true when either was showing.
    @discardableResult
    func closeVideoCovers() -> Bool {
        let wasShowing = shorts != nil || VideoPlayerModel.shared.isPresented
        shorts = nil
        VideoPlayerModel.shared.isPresented = false
        return wasShowing
    }

    /// Runs `present` once a full-screen cover that is being dismissed has gone, so the next one
    /// is not presented behind it.
    func afterCoverDismissal(_ wasShowing: Bool, _ present: @escaping @MainActor () -> Void) {
        guard wasShowing else { present(); return }
        Task { try? await Task.sleep(for: .milliseconds(500)); present() }
    }

    /// Opens shared YouTube / YouTube Music links (watch, youtu.be, shorts, playlist, channel).
    func open(url: URL) {
        if url.scheme == "koda", url.host == "nowplaying" {
            if MusicPlayer.shared.current != nil {
                mode = .music
                afterCoverDismissal(closeVideoCovers()) { self.showPlayer = true }
            }
            return
        }
        // The download Live Activity: the downloaded videos, in video mode.
        if url.scheme == "koda", url.host == "downloads" {
            mode = .video
            let wasShowing = closeVideoCovers() || showPlayer
            showPlayer = false
            afterCoverDismissal(wasShowing) {
                // From the tab's root, so tapping the activity again doesn't stack another copy.
                if self.tab == .settings { self.tab = .home }
                self.paths[self.tab] = NavigationPath()
                self.navigate(.videoDownloads)
            }
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
                let wasShowing = closeVideoCovers()
                Task {
                    let info = try? await InnerTube.shared.player(videoId: v)
                    // YouTube's auto-generated artist channels are named "Artist - Topic"; show just the artist.
                    let author = (info?.author ?? "").replacingOccurrences(of: " - Topic", with: "", options: [.anchored, .backwards])
                    let song = Song(id: v, title: info?.title ?? String(localized: "Song"), artist: author,
                                    duration: info.map { Int($0.duration) }, thumbnail: info?.thumbnail)
                    MusicPlayer.shared.play([song], radio: true)
                    afterCoverDismissal(wasShowing) { self.showPlayer = true }
                }
            } else {
                let wasShowing = shorts != nil || showPlayer
                shorts = nil
                showPlayer = false
                afterCoverDismissal(wasShowing) { VideoPlayerModel.shared.open(Video(id: v, title: "", channel: "")) }
            }
        } else if let list = query["list"] {
            if isMusic { mode = .music; navigate(.playlist(list)) } else { navigate(.videoPlaylist(list, String(localized: "Playlist"))) }
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
    /// The accent in light and dark: the dark-mode copy is lighter, so tinted text, glyphs and the selected
    /// tab keep at least 4.5:1 against a black background; the light copy of the paler palettes is deeper,
    /// for the same contrast against white.
    var color: Color {
        switch self {
        case .violet, .artwork: Self.dynamic(light: (0.40, 0.31, 0.64), dark: (0.58, 0.48, 0.90))
        case .emerald: Color(red: 0.11, green: 0.55, blue: 0.36)
        case .sunset: Self.dynamic(light: (0.82, 0.36, 0.15), dark: (0.93, 0.45, 0.24))
        case .ocean: Self.dynamic(light: (0.12, 0.47, 0.80), dark: (0.24, 0.56, 0.92))
        case .crimson: Self.dynamic(light: (0.78, 0.16, 0.23), dark: (0.90, 0.26, 0.32))
        case .blossom: Self.dynamic(light: (0.80, 0.27, 0.52), dark: (0.89, 0.38, 0.62))
        case .solar: Self.dynamic(light: (0.66, 0.47, 0.0), dark: (0.86, 0.65, 0.10))
        case .midnight: Self.dynamic(light: (0.25, 0.27, 0.55), dark: (0.48, 0.52, 0.92))
        }
    }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        })
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
