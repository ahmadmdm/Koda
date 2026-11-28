import SwiftUI
import AVKit

struct SystemVideoPlayer: UIViewControllerRepresentable {
    var player: AVPlayer
    /// A one-finger, mostly vertical pan down the inline video: its downward distance while it moves,
    /// then its distance and speed when it ends (or cancels, as 0). AVKit's own gestures (tap for the
    /// controls, scrubbing, pinch) run alongside it, and it never starts in fullscreen.
    var onPullDown: ((CGFloat) -> Void)? = nil
    var onPullDownEnded: ((_ distance: CGFloat, _ velocity: CGFloat) -> Void)? = nil

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        let pip = UserDefaults.standard.object(forKey: "pictureInPicture") as? Bool ?? true
        vc.allowsPictureInPicturePlayback = pip
        vc.canStartPictureInPictureAutomaticallyFromInline = pip
        // VideoPlayerModel publishes Now Playing itself, and only while the video owns it.
        vc.updatesNowPlayingInfoCenter = false
        vc.delegate = context.coordinator
        vc.speeds = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].map { AVPlaybackSpeed(rate: $0, localizedName: $0.speedLabel) }
        vc.entersFullScreenWhenPlaybackBegins = false
        vc.exitsFullScreenWhenPlaybackEnds = true
        // Captions live in the content overlay so they show inline, in fullscreen and on rotation.
        if let overlay = vc.contentOverlayView {
            let host = UIHostingController(rootView: CaptionOverlay().environment(VideoPlayerModel.shared))
            host.view.backgroundColor = .clear
            host.view.isUserInteractionEnabled = false
            host.view.translatesAutoresizingMaskIntoConstraints = false
            overlay.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            ])
            context.coordinator.host = host
        }
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        vc.view.addGestureRecognizer(pan)
        context.coordinator.onPullDown = onPullDown
        context.coordinator.onPullDownEnded = onPullDownEnded
        context.coordinator.watchAppState(vc, player: player)
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        context.coordinator.onPullDown = onPullDown
        context.coordinator.onPullDownEnded = onPullDownEnded
        // Keep the coordinator on the current player, and don't undo the background detach here:
        // SwiftUI can update the view while the app is in the background.
        context.coordinator.watchAppState(vc, player: player)
        if !context.coordinator.isDetached, vc.player !== player { vc.player = player }
        let pip = UserDefaults.standard.object(forKey: "pictureInPicture") as? Bool ?? true
        if vc.allowsPictureInPicturePlayback != pip {
            vc.allowsPictureInPicturePlayback = pip
            vc.canStartPictureInPictureAutomaticallyFromInline = pip
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var host: UIViewController?
        var onPullDown: ((CGFloat) -> Void)?
        var onPullDownEnded: ((CGFloat, CGFloat) -> Void)?
        private var isFullScreen = false
        private weak var controller: AVPlayerViewController?
        private var player: AVPlayer?
        /// The player was taken off the controller when the app went to the background.
        private(set) var isDetached = false
        private var observers: [NSObjectProtocol] = []

        /// Back from the background, the picture stayed frozen while the sound went on: the player view
        /// loses its video output when the app leaves (audio keeps playing in the background), and AVKit
        /// doesn't always reconnect it. Detach the player while in the background (unless Picture in
        /// Picture holds it), reattach on return, and seek to the current time so a fresh frame draws.
        func watchAppState(_ vc: AVPlayerViewController, player: AVPlayer) {
            controller = vc
            self.player = player
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let vc = self.controller, !VideoPlayerModel.shared.isPictureInPictureActive else { return }
                    vc.player = nil
                    self.isDetached = true
                }
            })
            observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reattach() }
            })
            observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reattach() }
            })
        }

        @MainActor private func reattach() {
            // Both foreground notifications arrive on return, and didBecomeActive also follows a
            // Control Center or notification pull-down: reattach and seek once, after a real detach.
            guard isDetached, let vc = controller, let player else { return }
            isDetached = false
            if vc.player !== player { vc.player = player }
            guard let item = player.currentItem, item.status == .readyToPlay else { return }
            let now = player.currentTime()
            guard now.isValid, now.seconds.isFinite else { return }
            let wasPlaying = player.timeControlStatus != .paused
            player.seek(to: now, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                if wasPlaying { Task { @MainActor in if player.rate == 0 { player.play() } } }
            }
        }

        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        @objc func pan(_ pan: UIPanGestureRecognizer) {
            // Window coordinates: the video itself moves with the finger.
            let space = pan.view?.window
            let distance = max(0, pan.translation(in: space).y)
            switch pan.state {
            case .changed: onPullDown?(distance)
            case .ended: onPullDownEnded?(distance, pan.velocity(in: space).y)
            case .cancelled, .failed: onPullDownEnded?(0, 0)
            default: break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, onPullDown != nil, !isFullScreen,
                  !VideoPlayerModel.shared.isPictureInPictureActive else { return false }
            let v = pan.velocity(in: pan.view)
            // Down, and clearly more down than sideways, so scrubbing and horizontal swipes stay AVKit's.
            return v.y > 0 && v.y > abs(v.x) * 1.5
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willBeginFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
            isFullScreen = true
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.isFullScreen = false }
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            VideoPlayerModel.shared.isPictureInPictureActive = true
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            VideoPlayerModel.shared.isPictureInPictureActive = false
        }

        func playerViewController(_ playerViewController: AVPlayerViewController,
                                  restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            // Back from the floating window: bring the watch page back if it was minimized.
            VideoPlayerModel.shared.isPresented = true
            completionHandler(true)
        }
    }
}

/// Subtitles drawn over the video, in the style of the system captions.
struct CaptionOverlay: View {
    @Environment(VideoPlayerModel.self) private var model
    @AppStorage("captionScale") private var scale: Double = 1
    @AppStorage("captionBackground") private var background = true

    var body: some View {
        GeometryReader { geo in
            VStack {
                Spacer()
                if let text = model.currentCaption {
                    Text(text)
                        .font(.system(size: max(13, geo.size.width / 34) * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black, radius: background ? 0 : 3)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(background ? AnyShapeStyle(.black.opacity(0.62)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, geo.size.height * 0.08)
                        .padding(.horizontal, 24)
                        .transition(.opacity)
                        .id(text)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.12), value: model.currentCaption)
        }
    }
}

/// Audio-language and subtitle choices for the playing video.
struct TrackMenus: View {
    @Environment(VideoPlayerModel.self) private var model
    @AppStorage("captionScale") private var scale: Double = 1
    @AppStorage("captionBackground") private var background = true

    var body: some View {
        if model.audioTracks.count > 1 {
            Menu {
                Picker("Audio track", selection: Binding(get: { model.selectedAudio }, set: { if let t = $0 { model.selectAudio(t) } })) {
                    ForEach(model.audioTracks) { t in
                        Text(t.isOriginal ? String(localized: "\(t.name) (Original)") : t.isDubbed ? String(localized: "\(t.name) (Dubbed)") : t.name).tag(Optional(t))
                    }
                }
            } label: {
                Image(systemName: model.selectedAudio?.isOriginal == false ? "waveform.badge.mic" : "waveform").frame(width: 40, height: 40)
            }
            .glassIconButton()
            .accessibilityLabel("Audio track")
        }
        if !model.captionTracks.isEmpty {
            Menu {
                Picker("Subtitles", selection: Binding(get: { model.selectedCaption }, set: { model.selectCaption($0) })) {
                    Text("Off").tag(CaptionTrack?.none)
                    ForEach(model.captionTracks) { t in
                        Text(t.isAutoGenerated ? String(localized: "\(t.name) (auto-generated)") : t.name).tag(Optional(t))
                    }
                }
                Section("Subtitle style") {
                    Picker("Size", selection: $scale) {
                        Text("Small").tag(0.8); Text("Medium").tag(1.0); Text("Large").tag(1.3); Text("Extra large").tag(1.6)
                    }
                    Toggle("Background", isOn: $background)
                }
            } label: {
                Image(systemName: model.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill").frame(width: 40, height: 40)
            }
            .glassIconButton()
            .accessibilityLabel("Subtitles")
        }
    }
}

struct WatchView: View {
    @Environment(VideoPlayerModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var app
    @Environment(CastManager.self) private var cast
    @State private var showComments = false
    @State private var showDescription = false
    @State private var showChat = false
    @State private var sidePanel = SidePanel.related
    @State private var width: CGFloat = 0
    /// How far the page is pulled down by a drag on the video or the top bar (see `pullEnded`).
    @State private var pull: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum SidePanel: Hashable { case related, comments }

    /// Side by side (video and details on the leading side, related or comments on the trailing side)
    /// when the window is wide enough: iPad landscape and large windows. iPhone keeps the stacked page.
    private var isWide: Bool { UIUserInterfaceIdiom.allowsWideLayout(sizeClass) && width >= 960 }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if isWide {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        videoSurface
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .padding(.horizontal)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                info
                                if !model.chapters.isEmpty { chapters }
                            }
                            .padding()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    sideColumn
                        .frame(width: min(420, width * 0.36))
                        .overlay { chatPanel }
                }
            } else {
                videoSurface
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        info
                        if !model.chapters.isEmpty { chapters }
                        upNextAndRelated
                    }
                    .padding()
                }
                .readableContentWidth(820)
                .overlay { chatPanel }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Color(.systemBackground))
        // Follows the finger, shrinking and fading a little, like a sheet pulled down.
        .clipShape(RoundedRectangle(cornerRadius: pull > 0 ? 36 : 0, style: .continuous))
        .scaleEffect(1 - min(pull / 1500, 0.1), anchor: .top)
        .offset(y: pull)
        .opacity(1 - min(pull / 1000, 0.3))
        .onAppear { pull = 0 }
        .sheet(isPresented: $showComments) {
            if let token = model.details?.commentsToken { CommentsView(token: token, count: model.details?.commentCount) }
        }
        .sheet(isPresented: $showDescription) { descriptionSheet }
        .sheet(isPresented: Binding(get: { PictureAdjustState.shared.isPresented }, set: { PictureAdjustState.shared.isPresented = $0 })) {
            PictureAdjustSheet()
        }
        .onChange(of: model.current?.id) {
            // A new video: its chat isn't the old one's, and its comments start on Related.
            sidePanel = .related
            showChat = false
        }
        .toastOverlay()
    }

    /// Live chat covers the area under the player, or the side column on wide windows.
    @ViewBuilder private var chatPanel: some View {
        if showChat, let chat = model.details?.liveChat {
            LiveChatPanel(source: chat) { showChat = false }
        }
    }

    private var topBar: some View {
        @Bindable var model = model
        // Six round buttons: explicit tight spacing so the bar fits an iPhone's width.
        return HStack(spacing: sizeClass == .regular ? 8 : 4) {
            Button { model.isPresented = false } label: { Image(systemName: "chevron.down").font(.headline).frame(width: 40, height: 40) }
                .glassIconButton()
                .accessibilityLabel("Minimize")
            Spacer()
            TrackMenus()
            if sizeClass == .regular {
                PictureMenu()
                CastButton()
                    .frame(width: 40, height: 40)
                    .padding(6)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Cast")
            }
            Menu {
                Picker("Quality", selection: $model.quality) { ForEach(VideoQualityCap.allCases) { Text($0.title).tag($0) } }
                if sizeClass != .regular {
                    PictureMenu(submenu: true)
                    // No room for a seventh button on an iPhone: Cast is in this menu.
                    Section { CastMenuItems() }
                }
            } label: {
                // iPad shows the quality name; iPhone an icon, with Picture inside this menu.
                if sizeClass == .regular {
                    Label(model.quality.title, systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                } else {
                    // Tinted while casting, so the state shows without opening the menu.
                    Image(systemName: cast.isConnected ? "tv" : "slider.horizontal.3").font(.headline).frame(width: 40, height: 40)
                        .foregroundStyle(cast.isConnected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(sizeClass == .regular ? .capsule : .circle)
            .tint(.primary)
            .accessibilityLabel(Text("Quality"))
            Button { model.close() } label: { Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40) }
                .glassIconButton()
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, sizeClass == .regular ? 16 : 10).padding(.bottom, 8)
        .contentShape(Rectangle())
        // Pulling the bar down minimizes too; taps still reach its buttons.
        .gesture(DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { v in
                guard pull > 0 || (v.translation.height > 0 && v.translation.height > abs(v.translation.width) * 1.5) else { return }
                pull = max(0, v.translation.height)
            }
            .onEnded { v in
                guard pull > 0 else { return }
                pullEnded(max(0, v.translation.height), velocity: v.velocity.height)
            })
    }

    /// Past a third of the way, or flicked down, the page minimizes to the mini player (as the chevron
    /// does; playback carries on). Otherwise it springs back.
    private func pullEnded(_ distance: CGFloat, velocity: CGFloat) {
        if distance > 140 || (distance > 40 && velocity > 900) {
            model.isPresented = false
        } else {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { pull = 0 }
        }
    }

    private var videoSurface: some View {
        ZStack {
            Color.black
            SystemVideoPlayer(player: model.player,
                              onPullDown: { pull = $0 },
                              onPullDownEnded: { pullEnded($0, velocity: $1) })
                .pictureFilter()
            if model.isCasting { CastingVideoOverlay() }
            if model.isLoading { ProgressView().tint(.white).controlSize(.large) }
            if let e = model.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                    Text(e).multilineTextAlignment(.center).font(.callout)
                    if model.current != nil { Button("Retry") { model.retry() }.buttonStyle(.glass) }
                }.foregroundStyle(.white).padding()
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .bottomLeading) {
            if let notice = model.skippedNotice {
                Label(notice, systemImage: "forward.end.fill").font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6).glassEffect(.regular, in: .capsule).padding(10)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut, value: model.skippedNotice)
    }

    @ViewBuilder private var upNextAndRelated: some View {
        if !model.userQueue.isEmpty { VideoQueueSection() }
        if let next = model.autoNext {
            HStack {
                Text("Up next").font(.headline)
                Spacer()
                Button { model.playNext() } label: { Label("Play", systemImage: "forward.fill") }.buttonStyle(.glass).tint(.primary).controlSize(.small)
            }
            VideoCard(video: next, compact: true)
        }
        if let related = model.details?.related, !related.isEmpty {
            Text("Related").font(.headline)
            // Filtered once, not again for every card.
            let visible = library.filtered(related)
            ForEach(visible.filter { $0.id != model.autoNext?.id }) { v in
                VideoCard(video: v, compact: true, queue: visible)
            }
        }
    }

    /// The trailing column of the wide layout.
    private var sideColumn: some View {
        VStack(spacing: 10) {
            if model.details?.commentsToken != nil {
                Picker("Panel", selection: $sidePanel) {
                    Text("Related").tag(SidePanel.related)
                    Text("Comments").tag(SidePanel.comments)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            if sidePanel == .comments, let token = model.details?.commentsToken {
                CommentsView(token: token, count: model.details?.commentCount)
                    .id(token)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) { upNextAndRelated }
                        .padding(.horizontal)
                        .padding(.bottom)
                }
            }
        }
        .padding(.trailing, 4)
    }

    private var info: some View {
        let d = model.details
        let video = model.current
        return VStack(alignment: .leading, spacing: 12) {
            Text(d?.title ?? video?.title ?? "").font(.title3.bold())
            Button { showDescription = true } label: {
                Text([d?.views, d?.date].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ") + "  " + String(localized: "more…"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            if let channel = d?.channel {
                HStack(spacing: 10) {
                    Button { if !channel.id.isEmpty { app.navigate(.channel(channel.id)) } } label: {
                        HStack(spacing: 10) {
                            Artwork(url: channel.avatar.flatMap(URL.init(string:)), cornerRadius: 20, placeholderIcon: "person.fill").frame(width: 40, height: 40)
                            VStack(alignment: .leading) {
                                Text(channel.name).font(.subheadline.weight(.semibold))
                                if let s = channel.subscribers { Text(s).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button(library.isSubscribed(channel.id) ? "Subscribed" : "Subscribe") { library.toggleSubscription(channel) }
                        .buttonStyle(library.isSubscribed(channel.id) ? AnyPrimitiveButtonStyle(.glass) : AnyPrimitiveButtonStyle(.glassProminent))
                }
            }
            if let video {
                ScrollView(.horizontal, showsIndicators: false) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button { library.toggleVideoLike(video) } label: {
                                Label(d?.likes ?? String(localized: "Like"), systemImage: library.isVideoLiked(video.id) ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }
                            Button { library.toggleWatchLater(video) } label: {
                                Label("Save", systemImage: library.isInWatchLater(video.id) ? "bookmark.fill" : "bookmark")
                            }
                            if !video.isLive && d?.liveChat?.isReplay != false {
                                VideoDownloadButton(video: d.map { var v = video; v.title = $0.title; v.channel = $0.channel.name; v.channelId = $0.channel.id; return v } ?? video)
                            }
                            if let chat = d?.liveChat {
                                Button { showChat.toggle() } label: {
                                    Label(chat.isReplay ? "Chat replay" : "Live chat", systemImage: showChat ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                                }
                            }
                            if d?.commentsToken != nil {
                                Button { if isWide { sidePanel = .comments } else { showComments = true } } label: { Label(d?.commentCount.map { String(localized: "Comments \($0)") } ?? String(localized: "Comments"), systemImage: "text.bubble") }
                            }
                            Button {
                                MusicPlayer.shared.play([video.asSong], radio: true)
                                model.close()
                            } label: { Label("Listen", systemImage: "headphones") }
                            ShareLink(item: URL(string: "https://youtu.be/\(video.id)")!) { Label("Share", systemImage: "square.and.arrow.up") }
                        }
                        .buttonStyle(.glass)
                        .tint(.primary)
                        .font(.subheadline)
                    }
                }
                // Scroll to the screen edges instead of clipping at the page's 16pt margin.
                .contentMargins(.horizontal, Spacing.m, for: .scrollContent)
                .padding(.horizontal, -Spacing.m)
            }
        }
    }

    private var chapters: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Chapters").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.chapters) { c in
                        Button { model.seek(to: c.time) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Int(c.time).formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.tint)
                                Text(c.title).font(.caption.weight(.medium)).lineLimit(2).frame(width: 130, alignment: .leading)
                            }
                            .padding(10)
                            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var descriptionSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.details?.title ?? "").font(.title3.bold())
                    Text([model.details?.views, model.details?.date].compactMap { $0 }.joined(separator: " • ")).font(.caption).foregroundStyle(.secondary)
                    LinkedText(text: model.details?.description ?? "") { model.seek(to: $0); showDescription = false }
                }
                .padding()
            }
            .navigationTitle("Description").navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

/// Text with tappable links and timestamps.
struct LinkedText: View {
    var text: String
    var onTimestamp: (Double) -> Void

    var body: some View {
        Text(attributed)
            .font(.callout)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "koda-seek", let t = Double(url.host ?? "") { onTimestamp(t); return .handled }
                return .systemAction
            })
    }

    // Built once: creating a detector and a regex for every comment on every render is costly.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let timestampRegex = try? NSRegularExpression(pattern: #"\b(?:\d{1,2}:)?\d{1,2}:\d{2}\b"#)

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let ns = text as NSString
        if let detector = Self.linkDetector {
            for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let r = Range(m.range, in: result), let url = m.url { result[r].link = url; result[r].foregroundColor = .accentColor }
            }
        }
        guard let regex = Self.timestampRegex else { return result }
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let r = Range(m.range, in: result), let secs = ns.substring(with: m.range).durationSeconds {
                result[r].link = URL(string: "koda-seek://\(secs)")
                result[r].foregroundColor = .accentColor
            }
        }
        return result
    }
}

struct CommentsView: View {
    var token: String
    var count: String?
    var endpoint = "next"
    @Environment(VideoPlayerModel.self) private var model
    @State private var comments: [Comment] = []
    @State private var next: String?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                ForEach(comments) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Artwork(url: c.avatar.flatMap(URL.init(string:)), cornerRadius: 16, placeholderIcon: "person.fill").frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(c.author) • \(c.published)").font(.caption).foregroundStyle(.secondary)
                            LinkedText(text: c.text) { model.seek(to: $0) }
                            HStack(spacing: 14) {
                                if let l = c.likes, !l.isEmpty { Label(l, systemImage: "hand.thumbsup").font(.caption) }
                                if let r = c.replyCount, !r.isEmpty, r != "0" { Label(r, systemImage: "arrowshape.turn.up.left").font(.caption) }
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                if let next, !comments.isEmpty { ProgressView().frame(maxWidth: .infinity).task(id: next) { await more() } }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
            .listStyle(.plain)
            .overlay { if loading && comments.isEmpty { LoadingView() } }
            .navigationTitle(count.map { Text("Comments \($0)") } ?? Text("Comments"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        // Keyed by the token: the sheet stays up when the next video starts, and must not keep the
        // old video's comments.
        .task(id: token) {
            comments = []; next = nil; error = nil; loading = true
            do {
                let (c, n) = try await VideoAPI.comments(token: token, endpoint: endpoint)
                comments = c; next = n
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    private func more() async {
        guard let token = next else { return }
        do {
            let (c, n) = try await VideoAPI.comments(token: token, endpoint: endpoint)
            // Another video's comments, or this page already handled: drop it.
            guard next == token else { return }
            let ids = Set(comments.map(\.id))
            let fresh = c.filter { !ids.contains($0.id) }
            comments += fresh
            // A page that adds nothing new would only bring the same spinner back.
            next = n == token || fresh.isEmpty ? nil : n
        } catch {
            // Scrolling the spinner away cancels the request; it should load again when it's back.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
            next = nil
        }
    }
}
