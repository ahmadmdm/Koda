import SwiftUI

@main
struct KodaApp: App {
    /// Hands Siri's "play … on Koda" requests to `KodaPlayMediaHandler` (Koda/CarPlay/).
    @UIApplicationDelegateAdaptor(KodaAppDelegate.self) private var appDelegate
    @State private var app = AppState()
    @State private var player = MusicPlayer.shared
    @State private var video = VideoPlayerModel.shared
    @State private var library = LibraryStore.shared
    @State private var downloads = DownloadManager.shared
    @State private var artworkTint = ArtworkTint.shared
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("palette") private var palette = Palette.violet.rawValue
    @AppStorage("onboarded") private var onboarded = false

    init() {
        Scrobbler.shared.start()
        Task { await LocalMusicLibrary.shared.rescan() }
        Diagnostics.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(player)
                .environment(video)
                .environment(library)
                .environment(downloads)
                .environment(artworkTint)
                .environment(AccountModel.shared)
                .tint(tint)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onOpenURL { app.open(url: $0) }
                .modifier(ArtworkCache())
                .sheet(isPresented: Binding(get: { !onboarded }, set: { if !$0 { onboarded = true } })) {
                    OnboardingView().environment(library).tint(tint)
                }
        }
    }

    /// iOS 27 lets AsyncImage use a custom URLSession: give artwork a 200 MB disk cache so covers
    /// scrolled past once load instantly afterwards.
    struct ArtworkCache: ViewModifier {
        static let session: URLSession = {
            let config = URLSessionConfiguration.default
            config.urlCache = URLCache(memoryCapacity: 40 << 20, diskCapacity: 200 << 20, directory: nil)
            config.requestCachePolicy = .returnCacheDataElseLoad
            return URLSession(configuration: config)
        }()

        func body(content: Content) -> some View {
            if #available(iOS 27.0, *) {
                content.asyncImageURLSession(Self.session)
            } else {
                content
            }
        }
    }

    private var tint: Color {
        let p = Palette(rawValue: palette) ?? .violet
        if p == .artwork, let c = artworkTint.color { return c }
        return p.color
    }
}
