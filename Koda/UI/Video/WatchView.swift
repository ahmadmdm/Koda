import SwiftUI
import AVKit

struct SystemVideoPlayer: UIViewControllerRepresentable {
    var player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
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
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var host: UIViewController?

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
    @State private var showComments = false
    @State private var showDescription = false
    @State private var showChat = false
    @State private var sidePanel = SidePanel.related
    @State private var width: CGFloat = 0
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
        .sheet(isPresented: $showComments) {
            if let token = model.details?.commentsToken { CommentsView(token: token, count: model.details?.commentCount) }
        }
        .sheet(isPresented: $showDescription) { descriptionSheet }
        .sheet(isPresented: Binding(get: { PictureAdjustState.shared.isPresented }, set: { PictureAdjustState.shared.isPresented = $0 })) {
            PictureAdjustSheet()
        }
        .onChange(of: model.current?.id) { sidePanel = .related }
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
            if sizeClass == .regular { PictureMenu() }
            Menu {
                Picker("Quality", selection: $model.quality) { ForEach(VideoQualityCap.allCases) { Text($0.title).tag($0) } }
                if sizeClass != .regular { PictureMenu(submenu: true) }
            } label: {
                // iPad shows the quality name; iPhone an icon, with Picture inside this menu.
                if sizeClass == .regular {
                    Label(model.quality.title, systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                } else {
                    Image(systemName: "slider.horizontal.3").font(.headline).frame(width: 40, height: 40)
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
    }

    private var videoSurface: some View {
        ZStack {
            Color.black
            SystemVideoPlayer(player: model.player)
                .pictureFilter()
            if model.isLoading { ProgressView().tint(.white).controlSize(.large) }
            if let e = model.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                    Text(e).multilineTextAlignment(.center).font(.callout)
                    if let v = model.current { Button("Retry") { let c = v; model.close(); model.open(c) }.buttonStyle(.glass) }
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

    private var attributed: AttributedString {
        var result = AttributedString(text)
        let ns = text as NSString
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                if let r = Range(m.range, in: result), let url = m.url { result[r].link = url; result[r].foregroundColor = .accentColor }
            }
        }
        let regex = try! NSRegularExpression(pattern: #"\b(?:\d{1,2}:)?\d{1,2}:\d{2}\b"#)
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
        .task {
            do { (comments, next) = try await VideoAPI.comments(token: token, endpoint: endpoint) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private func more() async {
        guard let token = next else { return }
        if let (c, n) = try? await VideoAPI.comments(token: token, endpoint: endpoint), !c.isEmpty {
            let ids = Set(comments.map(\.id))
            let fresh = c.filter { !ids.contains($0.id) }
            comments += fresh
            // A page that adds nothing new would only bring the same spinner back.
            next = n == token || fresh.isEmpty ? nil : n
        } else { next = nil }
    }
}
