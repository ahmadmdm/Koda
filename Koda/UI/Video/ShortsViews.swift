import SwiftUI
import AVFoundation
import Observation

/// What opens the Shorts pager: the Shorts to start with, the first one shown first.
struct ShortsLaunch: Identifiable {
    let id = UUID()
    var items: [ShortItem]
}

// MARK: Feed

/// The pager's list: the launch items, then YouTube's reel sequence after them
/// (the first item's `sequenceParams`, else the seedless Shorts start).
@MainActor
@Observable
final class ShortsFeed {
    private(set) var items: [ShortItem]
    private(set) var details: [String: ShortDetails] = [:]
    private(set) var isLoadingMore = false
    @ObservationIgnored private var continuation: String?
    @ObservationIgnored private var exhausted = false
    @ObservationIgnored private var detailRequests = Set<String>()

    init(_ launch: ShortsLaunch) {
        var seen = Set<String>()
        items = launch.items.filter { seen.insert($0.id).inserted }
        continuation = items.first?.sequenceParams
    }

    func loadMoreIfNeeded(near id: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }), index >= items.count - 3,
              !isLoadingMore, !exhausted else { return }
        isLoadingMore = true; defer { isLoadingMore = false }
        do {
            var page: ShortsPage
            if let token = continuation {
                page = try await ShortsAPI.sequence(token)
            } else {
                let seed = try await ShortsAPI.seedless()
                page = seed
                if let token = seed.continuation, let more = try? await ShortsAPI.sequence(token) {
                    page = ShortsPage(items: seed.items + more.items, continuation: more.continuation ?? token)
                }
            }
            let usedSeedless = continuation == nil
            let known = Set(items.map(\.id))
            let fresh = page.items.filter { !known.contains($0.id) && !LibraryStore.shared.data.hiddenVideos.contains($0.id) }
            items += fresh
            // A sequence that ends or only repeats falls back to a fresh seedless start.
            if fresh.isEmpty {
                if usedSeedless { exhausted = true }
                continuation = nil
            } else {
                continuation = page.continuation
            }
        } catch {
            if continuation == nil { exhausted = true }
            continuation = nil
        }
    }

    func loadDetails(_ id: String) async {
        guard details[id] == nil, detailRequests.insert(id).inserted else { return }
        if let d = try? await ShortsAPI.details(id) { details[id] = d } else { detailRequests.remove(id) }
    }
}

// MARK: Playback

/// One Short's own AVPlayer: HLS from the visionOS `/player`, looping, never the shared VideoPlayerModel.
@MainActor
@Observable
final class ShortPlayer {
    let id: String
    @ObservationIgnored let player = AVPlayer()
    private(set) var isReady = false
    private(set) var error: String?
    private(set) var progress: Double = 0
    private(set) var isPortrait = true
    var userPaused = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var sizeObservation: NSKeyValueObservation?

    init(id: String, muted: Bool) {
        self.id = id
        player.isMuted = muted
        player.allowsExternalPlayback = false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.progress = min(max(t.seconds / d, 0), 1)
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let ended, let item = self.player.currentItem, ended == ObjectIdentifier(item) else { return }
                self.player.seek(to: .zero)
                if self.active && !self.userPaused { self.player.play() }
            }
        }
        load()
    }

    private func load() {
        task = Task {
            do {
                let info = try await InnerTube.shared.player(videoId: id)
                guard !Task.isCancelled else { return }
                guard let url = info.hlsURL else { throw InnerTubeError.noStream }
                let item = AVPlayerItem(asset: AVURLAsset(url: url))
                item.preferredForwardBufferDuration = 4
                observe(item)
                player.replaceCurrentItem(with: item)
                if active && !userPaused { player.play() }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status) { @Sendable [weak self] item, _ in
            let ready = item.status == .readyToPlay
            Task { @MainActor in if ready { self?.isReady = true } }
        }
        sizeObservation = item.observe(\.presentationSize) { @Sendable [weak self] item, _ in
            let size = item.presentationSize
            Task { @MainActor in if size.width > 0 { self?.isPortrait = size.height >= size.width } }
        }
    }

    func setActive(_ value: Bool) {
        active = value
        if value {
            if !userPaused { player.play() }
        } else {
            player.pause()
        }
    }

    func togglePause() {
        userPaused.toggle()
        if userPaused { player.pause() } else if active { player.play() }
    }

    func setMuted(_ muted: Bool) { player.isMuted = muted }

    /// Called when the page leaves the window around the visible Short.
    func tearDown() {
        task?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil; endObserver = nil
        statusObservation = nil; sizeObservation = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// A bare AVPlayerLayer, so the Shorts overlay is all SwiftUI.
struct ShortVideoSurface: UIViewRepresentable {
    var player: AVPlayer
    var fill: Bool

    final class SurfaceView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.backgroundColor = .clear
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

// MARK: Pager

struct ShortsPagerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @State private var feed: ShortsFeed
    @State private var currentID: String?
    @State private var players: [String: ShortPlayer] = [:]
    @State private var comments: ShortDetails?
    @AppStorage("shortsMuted") private var muted = false

    init(launch: ShortsLaunch) {
        _feed = State(initialValue: ShortsFeed(launch))
        _currentID = State(initialValue: launch.items.first?.id)
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(feed.items) { item in
                        ShortPageView(item: item, details: feed.details[item.id], player: players[item.id],
                                      insets: geo.safeAreaInsets,
                                      onComments: { comments = feed.details[item.id] },
                                      onChannel: { id in dismiss(); app.navigate(.channel(id)) },
                                      onLeave: leave)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(item.id)
                    }
                    if feed.isLoadingMore {
                        ProgressView().tint(.white).frame(maxWidth: .infinity).frame(height: 80)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .overlay(alignment: .top) {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40) }
                        .buttonStyle(.glass).buttonBorderShape(.circle)
                        .accessibilityLabel("Close")
                    Spacer()
                    Text("Shorts").font(.headline).foregroundStyle(.white).shadow(radius: 4)
                    Spacer()
                    Button { muted.toggle() } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.headline).frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass).buttonBorderShape(.circle)
                    .accessibilityLabel(muted ? "Unmute" : "Mute")
                }
                .padding(.horizontal)
            }
        }
        .background(.black)
        .environment(\.colorScheme, .dark)
        .sheet(item: Binding(get: { comments.flatMap { d in d.commentsToken.map { CommentsSheetItem(token: $0, count: d.commentCount) } } },
                             set: { if $0 == nil { comments = nil } })) { c in
            CommentsView(token: c.token, count: c.count, endpoint: "browse")
        }
        .onAppear {
            MusicPlayer.shared.pause()
            VideoPlayerModel.shared.player.pause()
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            activate(currentID)
        }
        .onDisappear {
            for p in players.values { p.tearDown() }
            players = [:]
        }
        .onChange(of: currentID) { _, id in activate(id) }
        .onChange(of: muted) { _, m in for p in players.values { p.setMuted(m) } }
        .onChange(of: feed.items.count) { activate(currentID, preloadOnly: true) }
    }

    /// Closes the pager before something else plays: pauses every Short so audio never overlaps,
    /// then runs `then` once the cover has gone, so a new player is not presented behind it.
    private func leave(then: @escaping @MainActor () -> Void) {
        for p in players.values { p.setActive(false) }
        app.afterCoverDismissal(app.shorts != nil, then)
        app.shorts = nil
    }

    /// Keeps players for the visible Short and its neighbours; only the visible one plays.
    private func activate(_ id: String?, preloadOnly: Bool = false) {
        guard let id, let index = feed.items.firstIndex(where: { $0.id == id }) else { return }
        let window = Set(feed.items[max(0, index - 1)...min(feed.items.count - 1, index + 1)].map(\.id))
        for (key, p) in players where !window.contains(key) { p.tearDown(); players[key] = nil }
        for key in window where players[key] == nil { players[key] = ShortPlayer(id: key, muted: muted) }
        if !preloadOnly {
            for (key, p) in players { p.setActive(key == id) }
        }
        Task {
            await feed.loadDetails(id)
            if index + 1 < feed.items.count { await feed.loadDetails(feed.items[index + 1].id) }
        }
        Task { await feed.loadMoreIfNeeded(near: id) }
    }
}

private struct CommentsSheetItem: Identifiable {
    var id: String { token }
    var token: String
    var count: String?
}

struct ShortPageView: View {
    var item: ShortItem
    var details: ShortDetails?
    var player: ShortPlayer?
    var insets: EdgeInsets
    var onComments: () -> Void
    var onChannel: (String) -> Void
    var onLeave: (@escaping @MainActor () -> Void) -> Void
    @Environment(LibraryStore.self) private var library

    private var video: Video {
        Video(id: item.id, title: details?.title ?? item.title, channel: details?.channel?.name ?? "",
              channelId: details?.channel?.id, channelAvatar: details?.channel?.avatar,
              thumbnail: item.thumbnail, views: details?.views ?? item.views)
    }

    var body: some View {
        ZStack {
            Color.black
            if player?.isReady != true {
                Artwork(url: item.thumbnailURL, cornerRadius: 0, placeholderIcon: "play.rectangle")
            }
            if let player {
                ShortVideoSurface(player: player.player, fill: player.isPortrait)
                    .opacity(player.isReady ? 1 : 0)
            }
            if let error = player?.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                    Text(verbatim: error).font(.callout).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white).padding(32)
            } else if player?.isReady != true {
                ProgressView().tint(.white).controlSize(.large)
            }
            if player?.userPaused == true {
                Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.85)).shadow(radius: 8)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { player?.togglePause() }
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .frame(height: 260).allowsHitTesting(false)
        }
        .overlay(alignment: .bottomLeading) { caption }
        .overlay(alignment: .bottomTrailing) { actions }
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                Capsule().fill(.white.opacity(0.25)).overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: g.size.width * (player?.progress ?? 0))
                }
            }
            .frame(height: 2)
            .padding(.horizontal, 12)
            .padding(.bottom, insets.bottom + 4)
            .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let channel = details?.channel {
                HStack(spacing: 8) {
                    Button { onChannel(channel.id) } label: {
                        HStack(spacing: 8) {
                            Artwork(url: channel.avatar.flatMap(URL.init(string:)), cornerRadius: 16, placeholderIcon: "person.fill")
                                .frame(width: 32, height: 32)
                            Text(verbatim: channel.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    Button(library.isSubscribed(channel.id) ? "Subscribed" : "Subscribe") { library.toggleSubscription(channel) }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(library.isSubscribed(channel.id) ? AnyPrimitiveButtonStyle(.glass) : AnyPrimitiveButtonStyle(.glassProminent))
                        .controlSize(.small)
                }
            }
            let title = details?.title ?? item.title
            if !title.isEmpty { Text(verbatim: title).font(.subheadline).lineLimit(3) }
            let meta = [details?.views ?? item.views, details?.published].compactMap { $0 }.filter { !$0.isEmpty }
            if !meta.isEmpty { Text(verbatim: meta.joined(separator: " • ")).font(.caption).foregroundStyle(.white.opacity(0.75)) }
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
        .padding(.leading, 16)
        .padding(.trailing, 84)
        .padding(.bottom, insets.bottom + 20)
    }

    private var actions: some View {
        VStack(spacing: 18) {
            let liked = library.isVideoLiked(item.id)
            actionButton(liked ? "hand.thumbsup.fill" : "hand.thumbsup", details?.likes ?? String(localized: "Like")) {
                library.toggleVideoLike(video)
            }
            if details?.commentsToken != nil {
                actionButton("text.bubble.fill", details?.commentCount ?? String(localized: "Comments"), action: onComments)
            }
            ShareLink(item: item.shareURL) {
                actionLabel("arrowshape.turn.up.right.fill", String(localized: "Share"))
            }
            .buttonStyle(.plain)
            Menu {
                Button("Watch in Player", systemImage: "play.rectangle") {
                    let video = video
                    onLeave { VideoPlayerModel.shared.open(video) }
                }
                Button("Play as Audio", systemImage: "headphones") {
                    let song = video.asSong
                    onLeave { MusicPlayer.shared.play([song], radio: true) }
                }
                Button(library.isInWatchLater(item.id) ? "Remove from Watch Later" : "Watch Later", systemImage: "clock") { library.toggleWatchLater(video) }
            } label: {
                actionLabel("ellipsis", nil)
            }
        }
        .padding(.trailing, 12)
        .padding(.bottom, insets.bottom + 24)
    }

    private func actionButton(_ icon: String, _ label: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) { actionLabel(icon, label) }.buttonStyle(.plain)
    }

    private func actionLabel(_ icon: String, _ label: String?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.title3).frame(width: 48, height: 48).glassEffect(.regular.interactive(), in: .circle)
            if let label { Text(verbatim: label).font(.caption2.weight(.semibold)).lineLimit(1).shadow(radius: 3) }
        }
        .frame(minWidth: 56)
    }
}

// MARK: Shelves

/// A horizontal row of Shorts that opens the pager at the tapped one.
struct ShortsShelf: View {
    enum Source: Hashable { case search(String), channel(String) }
    var source: Source
    @Environment(AppState.self) private var app
    @Environment(LibraryStore.self) private var library
    @State private var items: [ShortItem] = []

    var body: some View {
        let visible = items.filter { !library.data.hiddenVideos.contains($0.id) }
        // A VStack, not a Group: an empty Group is no view at all, so its .task would never run.
        VStack(alignment: .leading, spacing: 0) {
            if !visible.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Shorts", systemImage: "play.rectangle.on.rectangle.fill").font(.title3.bold()).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                                Button { app.shorts = ShortsLaunch(items: Array(visible[index...])) } label: { ShortCard(item: item) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .task(id: source) {
            switch source {
            case .search(let q): items = (try? await ShortsAPI.search(q)) ?? []
            case .channel(let id): items = (try? await ShortsAPI.channel(id)) ?? []
            }
        }
    }
}

struct ShortCard: View {
    var item: ShortItem

    var body: some View {
        Artwork(url: item.thumbnailURL, cornerRadius: 14, placeholderIcon: "play.rectangle")
            .frame(width: 140, height: 249)
            .overlay {
                LinearGradient(colors: [.clear, .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.title).font(.caption.weight(.semibold)).lineLimit(2)
                    if let views = item.views { Text(verbatim: views).font(.caption2).opacity(0.8) }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 3)
                .padding(8)
            }
    }
}
