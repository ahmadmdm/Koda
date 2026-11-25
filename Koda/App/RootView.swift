import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(MusicPlayer.self) private var player
    @Environment(VideoPlayerModel.self) private var video
    @Environment(ArtworkTint.self) private var artworkTint
    @Namespace private var playerNamespace

    var body: some View {
        @Bindable var app = app
        @Bindable var video = video
        TabView(selection: $app.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                NavigationStack(path: app.path(.home)) {
                    Group {
                        if app.mode == .music { MusicHomeView() } else { VideoHomeView() }
                    }
                    .kodaDestinations()
                }
            }
            if app.mode == .video {
                Tab("Subscriptions", systemImage: "rectangle.stack.badge.play.fill", value: AppTab.subscriptions) {
                    NavigationStack(path: app.path(.subscriptions)) { SubscriptionsView().kodaDestinations() }
                }
            }
            Tab("Library", systemImage: app.mode == .music ? "music.note.square.stack.fill" : "play.square.stack.fill", value: AppTab.library) {
                NavigationStack(path: app.path(.library)) {
                    Group {
                        if app.mode == .music { MusicLibraryView() } else { VideoLibraryView() }
                    }
                    .kodaDestinations()
                }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                NavigationStack(path: app.path(.settings)) { SettingsView().kodaDestinations() }
            }
            Tab(value: AppTab.search, role: .search) {
                NavigationStack(path: app.path(.search)) {
                    Group {
                        if app.mode == .music { MusicSearchView() } else { VideoSearchView() }
                    }
                    .kodaDestinations()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory(isEnabled: player.current != nil || video.current != nil) {
            Group {
                if video.current != nil && (app.mode == .video || player.current == nil) {
                    VideoMiniPlayer()
                } else {
                    MiniPlayer()
                        .matchedTransitionSource(id: "player", in: playerNamespace)
                        .onTapGesture { app.showPlayer = true }
                }
            }
        }
        .fullScreenCover(isPresented: $app.showPlayer) {
            PlayerView()
                .navigationTransition(.zoom(sourceID: "player", in: playerNamespace))
        }
        .fullScreenCover(isPresented: $video.isPresented) {
            WatchView()
        }
        .fullScreenCover(item: $app.shorts) { ShortsPagerView(launch: $0) }
        // The full-screen player presents its own copy; this one only shows when nothing covers the root.
        .addToPlaylistPresenter(isActive: !app.showPlayer && !video.isPresented && app.shorts == nil)
        .toastOverlay()
        .task(id: player.current?.id) { await artworkTint.update(from: player.current?.artwork) }
        .task { player.prepareRestoredSession() }
        .modifier(AccountPresenter())
    }
}
