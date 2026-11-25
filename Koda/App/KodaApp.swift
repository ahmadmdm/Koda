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
        // Nothing here is needed for the first frame: the Last.fm queue and Keychain read, the Music
        // folder scan and saving MetricKit's reports wait until the UI is up.
        Task {
            try? await Task.sleep(for: .seconds(1))
            Scrobbler.shared.start()
            await LocalMusicLibrary.shared.rescan()
        }
        Task.detached(priority: .utility) { Diagnostics.shared.start() }
        // The background download session has to exist at launch to hear about downloads that ran while Koda was closed.
        _ = VideoDownloadManager.shared
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

    /// iOS 27 lets AsyncImage use a custom URLSession: give it the artwork session and its 200 MB disk
    /// cache, so any AsyncImage shares the covers `Artwork` has already downloaded.
    struct ArtworkCache: ViewModifier {
        static var session: URLSession { ArtworkLoader.session }

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
