import SwiftUI
import AVKit

struct PlayerView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var app
    @Environment(ArtworkTint.self) private var tint
    @Environment(\.dismiss) private var dismiss
    @AppStorage("playerStyle") private var styleRaw = PlayerStyle.classic.rawValue
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var showStylePicker = false
    @State private var dragOffset: CGFloat = 0
    @State private var sidePanel = SidePanel.lyrics
    @Environment(\.horizontalSizeClass) private var sizeClass

    enum SidePanel: Hashable { case lyrics, queue }

    private var isWide: Bool { UIUserInterfaceIdiom.allowsWideLayout(sizeClass) }

    private var style: PlayerStyle { PlayerStyle(rawValue: styleRaw) ?? .classic }

    var body: some View {
        ZStack {
            PlayerBackground(style: style)
            VStack(spacing: 0) {
                header
                if isWide {
                    wideBody
                } else {
                    if showLyrics {
                        LyricsPanel().transition(.opacity.combined(with: .scale(scale: 0.96)))
                        PlayerControls(compact: true).padding(.horizontal, 24).padding(.bottom, 8)
                    } else {
                        styleBody.transition(.opacity)
                    }
                    bottomBar
                }
            }
        }
        // On a wide layout lyrics and the queue are always beside the artwork, so the Bento tiles pick the panel instead.
        .onChange(of: showLyrics) { _, on in if on && isWide { sidePanel = .lyrics; showLyrics = false } }
        .onChange(of: showQueue) { _, on in if on && isWide { sidePanel = .queue; showQueue = false } }
        .offset(y: dragOffset)
        .gesture(DragGesture().onChanged { v in if v.translation.height > 0 { dragOffset = v.translation.height } }
            .onEnded { v in if v.translation.height > 140 { dismiss() }; withAnimation(.spring) { dragOffset = 0 } })
        .animation(.smooth(duration: 0.35), value: showLyrics)
        .animation(.smooth(duration: 0.35), value: styleRaw)
        // While the queue sheet is up it presents the playlist sheet itself.
        .addToPlaylistPresenter(isActive: !showQueue)
        .sheet(isPresented: $showQueue) { QueueView(presentsAddToPlaylist: true).presentationDetents([.medium, .large]).presentationBackground(.thinMaterial) }
        .sheet(isPresented: $showStylePicker) { StylePicker(selection: $styleRaw).presentationDetents([.height(330)]) }
        .alert("Playback", isPresented: Binding(get: { player.errorMessage != nil }, set: { if !$0 { player.errorMessage = nil } })) {
            Button("OK") {}
        } message: { Text(player.errorMessage ?? "") }
    }

    @ViewBuilder private var styleBody: some View {
        switch style {
        case .classic: ClassicStyle(onLongPress: { showStylePicker = true })
        case .hero: HeroStyle(onLongPress: { showStylePicker = true })
        case .editorial: EditorialStyle(onLongPress: { showStylePicker = true })
        case .canvas: CanvasStyle(onLongPress: { showStylePicker = true })
        case .bento: BentoStyle(onLongPress: { showStylePicker = true }, showLyrics: $showLyrics, showQueue: $showQueue)
        case .dial: DialStyle(onLongPress: { showStylePicker = true })
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.down").font(.headline).frame(width: GlassControl.glassIcon, height: GlassControl.glassIcon) }
                .glassIconButton()
                .accessibilityLabel("Close")
            Spacer()
            VStack(spacing: 0) {
                Text("PLAYING FROM").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(player.current?.album ?? (player.radioEnabled ? String(localized: "Radio") : String(localized: "Queue"))).font(.footnote.weight(.semibold)).lineLimit(1)
            }
            .padding(.horizontal, Spacing.xs)
            Spacer()
            PlayerMenu(showStylePicker: $showStylePicker)
        }
        .padding(.horizontal, Spacing.l).padding(.top, Spacing.xs)
    }

    /// iPad and other wide windows: the player style on the leading side, lyrics or the queue on the trailing side.
    private var wideBody: some View {
        HStack(spacing: 0) {
            styleBody
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Picker("Panel", selection: $sidePanel) {
                        Text("Lyrics").tag(SidePanel.lyrics)
                        Text("Up Next").tag(SidePanel.queue)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    Spacer()
                    AirPlayGlassButton()
                }
                .padding(.horizontal, Spacing.l)
                Group {
                    switch sidePanel {
                    case .lyrics: LyricsPanel()
                    case .queue: QueueView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 28))
            }
            .padding(.vertical, 12)
            .padding(.trailing, 20)
            .frame(maxWidth: .infinity)
        }
    }

    private var bottomBar: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 18) {
                Button { showLyrics.toggle() } label: {
                    Image(systemName: showLyrics ? "quote.bubble.fill" : "quote.bubble").frame(width: GlassControl.glassIcon, height: GlassControl.glassIcon)
                }
                .glassIconButton()
                .accessibilityLabel("Lyrics")
                .accessibilityAddTraits(showLyrics ? .isSelected : [])
                Spacer()
                AirPlayGlassButton()
                Spacer()
                Button { showQueue = true } label: { Image(systemName: "list.bullet").frame(width: GlassControl.glassIcon, height: GlassControl.glassIcon) }
                    .glassIconButton()
                    .accessibilityLabel("Queue")
            }
        }
        .font(.title3)
        .padding(.horizontal, 28).padding(.bottom, Spacing.s)
    }
}

// MARK: Shared pieces

struct PlayerBackground: View {
    var style: PlayerStyle
    @Environment(MusicPlayer.self) private var player
    @Environment(ArtworkTint.self) private var tint
    @AppStorage("ambientBackground") private var ambient = true

    var body: some View {
        ZStack {
            Color(.systemBackground)
            if ambient || style == .canvas {
                Artwork(url: player.current?.largeArtwork ?? player.current?.artwork, cornerRadius: 0)
                    .scaleEffect(style == .canvas ? 1.1 : 1.6)
                    .blur(radius: style == .canvas ? 18 : 70)
                    .opacity(style == .canvas ? 0.9 : 0.55)
                LinearGradient(colors: [(tint.colors.first ?? .accentColor).opacity(0.35), Color(.systemBackground).opacity(style == .canvas ? 0.25 : 0.7)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

struct ArtworkGestures: ViewModifier {
    var onLongPress: () -> Void
    @Environment(MusicPlayer.self) private var player
    func body(content: Content) -> some View {
        content
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { player.skip(by: -10) }
                    Color.clear.contentShape(Rectangle()).onTapGesture(count: 2) { player.skip(by: 10) }
                }
            }
            .onLongPressGesture(minimumDuration: 0.5) { onLongPress() }
            .accessibilityHint("Double-tap either side to seek. Long-press to change the player style.")
    }
}

struct TitleBlock: View {
    var alignment: HorizontalAlignment = .leading
    var titleFont: Font = .title2.bold()
    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: alignment, spacing: 4) {
                Text(player.current?.title ?? "").font(titleFont).lineLimit(2)
                Button {
                    if let id = player.current?.artistId { app.navigate(.artist(id)) }
                } label: {
                    Text(player.current?.artist ?? "").font(.title3).foregroundStyle(.secondary).lineLimit(1)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
            if let song = player.current {
                Button { library.toggleLike(song) } label: {
                    Image(systemName: library.isLiked(song) ? "heart.fill" : "heart")
                        .font(.title2).foregroundStyle(library.isLiked(song) ? .pink : .primary)
                        .symbolEffect(.bounce, value: library.isLiked(song))
                        .frame(width: GlassControl.glassIcon, height: GlassControl.glassIcon)
                }
                .glassIconButton()
                .accessibilityLabel(library.isLiked(song) ? "Remove from Liked" : "Like")
            }
        }
    }
}

struct SeekBar: View {
    @Environment(MusicPlayer.self) private var player
    @State private var dragging: Double?

    var body: some View {
        let duration = max(player.duration, 1)
        let value = dragging ?? player.currentTime
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.15))
                    Capsule().fill(.primary).frame(width: max(0, geo.size.width * min(value / duration, 1)))
                }
                .frame(height: dragging == nil ? 6 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in dragging = min(max(0, g.location.x / geo.size.width), 1) * duration }
                    .onEnded { _ in if let d = dragging { player.seek(to: d) }; dragging = nil })
                .animation(.spring(duration: 0.25), value: dragging == nil)
            }
            .frame(height: 22)
            HStack {
                Text(value.formattedDuration)
                Spacer()
                Text("-" + max(0, duration - value).formattedDuration)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct PlayerControls: View {
    var compact = false
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        GlassEffectContainer(spacing: 24) {
            HStack(spacing: 0) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)).frame(width: 36, height: 44)
                }
                .accessibilityLabel("Shuffle")
                .accessibilityValue(player.shuffle ? Text("On") : Text("Off"))
                Spacer()
                Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title2).frame(width: 42, height: 42) }
                    .glassIconButton()
                    .accessibilityLabel("Previous")
                Spacer()
                Button { player.togglePlay() } label: {
                    ZStack {
                        if player.isLoading { ProgressView().controlSize(.large).tint(.white) }
                        else {
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: compact ? 26 : 32)).contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: compact ? 52 : 64, height: compact ? 52 : 64)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.circle)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Spacer()
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title2).frame(width: 42, height: 42) }
                    .glassIconButton()
                    .accessibilityLabel("Next")
                Spacer()
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode.icon).foregroundStyle(player.repeatMode == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)).frame(width: 36, height: 44)
                }
                .accessibilityLabel("Repeat")
                .accessibilityValue(repeatValue)
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
        .environment(\.layoutDirection, .leftToRight)
    }

    private var repeatValue: Text {
        switch player.repeatMode {
        case .off: Text("Off")
        case .one: Text("Repeat One")
        case .all: Text("Repeat All")
        }
    }
}

/// The AirPlay route picker in the same round glass as the player's other buttons: the same outer
/// size as a `.glass` circle button with a 44pt glyph frame, and a primary glyph.
struct AirPlayGlassButton: View {
    var body: some View {
        AirPlayButton()
            .frame(width: GlassControl.glassIcon, height: GlassControl.glassIcon)
            .padding(6)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("AirPlay")
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.tintColor = .label
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PlayerMenu: View {
    @Binding var showStylePicker: Bool
    @Environment(MusicPlayer.self) private var player
    @Environment(AppState.self) private var app
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        Menu {
            if let song = player.current {
                Button("Add to Playlist…", systemImage: "text.badge.plus") { app.addToPlaylist = [song] }
                if !downloads.isDownloaded(song.id) {
                    Button("Download", systemImage: "arrow.down.circle") { downloads.download([song]) }
                }
                Button("Start Radio", systemImage: "dot.radiowaves.left.and.right") { player.startRadio(from: song) }
                if let id = song.artistId { Button("Go to Artist", systemImage: "music.microphone") { app.navigate(.artist(id)) } }
                if let id = song.albumId { Button("Go to Album", systemImage: "square.stack") { app.navigate(.album(id)) } }
                ShareLink(item: URL(string: "https://music.youtube.com/watch?v=\(song.id)")!) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            Divider()
            Menu("Playback Speed", systemImage: "gauge.with.dots.needle.67percent") {
                Picker("Speed", selection: Binding(get: { player.rate }, set: { player.rate = $0 })) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0] as [Float], id: \.self) { Text($0.speedLabel).tag($0) }
                }
            }
            Menu("Sleep Timer", systemImage: player.sleepTimerEnd != nil || player.sleepAtEndOfTrack ? "moon.zzz.fill" : "moon.zzz") {
                ForEach([5, 15, 30, 45, 60, 90], id: \.self) { m in Button("\(m) minutes") { player.setSleepTimer(minutes: m) } }
                Button("End of track") { player.sleepAtEnd() }
                if player.sleepTimerEnd != nil || player.sleepAtEndOfTrack { Button("Turn Off", role: .destructive) { player.setSleepTimer(minutes: nil) } }
            }
            Button("Player Style…", systemImage: "paintbrush") { showStylePicker = true }
        } label: {
            Image(systemName: "ellipsis").font(.headline).frame(width: GlassControl.glassIcon, height: GlassControl.glassIcon)
        }
        .glassIconButton()
        .accessibilityLabel("More")
    }
}

struct StylePicker: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Player Style").font(.title2.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.s), count: 3), spacing: Spacing.s) {
                ForEach(PlayerStyle.allCases) { s in
                    let selected = selection == s.rawValue
                    Button { selection = s.rawValue; dismiss() } label: {
                        VStack(spacing: Spacing.xs) {
                            Image(systemName: s.icon).font(.title).frame(height: 32)
                            Text(s.title).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .contentShape(.rect(cornerRadius: Radius.large))
                    }
                    .buttonStyle(.plain)
                    .background(selected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.primary.opacity(0.06)), in: .rect(cornerRadius: Radius.large))
                    .overlay(RoundedRectangle(cornerRadius: Radius.large).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .padding(Spacing.xl)
    }
}

// MARK: Styles

struct ClassicStyle: View {
    var onLongPress: () -> Void
    @Environment(MusicPlayer.self) private var player
    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 8)
            Artwork(url: player.current?.largeArtwork ?? player.current?.artwork, cornerRadius: 20)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
                .scaleEffect(player.isPlaying ? 1 : 0.88)
                .animation(.spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
                .modifier(ArtworkGestures(onLongPress: onLongPress))
                .padding(.horizontal, 28)
            Spacer(minLength: 8)
            VStack(spacing: 18) {
                TitleBlock()
                SeekBar()
                PlayerControls()
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 16)
        }
    }
}

struct HeroStyle: View {
    var onLongPress: () -> Void
    @Environment(MusicPlayer.self) private var player
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                Artwork(url: player.current?.largeArtwork ?? player.current?.artwork, cornerRadius: 0)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.6), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                    .modifier(ArtworkGestures(onLongPress: onLongPress))
            }
            .ignoresSafeArea(edges: .horizontal)
            VStack(spacing: 18) {
                TitleBlock(titleFont: .largeTitle.weight(.heavy))
                SeekBar()
                PlayerControls()
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
    }
}

struct EditorialStyle: View {
    var onLongPress: () -> Void
    @Environment(MusicPlayer.self) private var player
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(player.current?.title ?? "")
                .font(.system(size: 54, weight: .black, design: .serif))
                .lineLimit(3).minimumScaleFactor(0.5)
                .padding(.top, 20)
            HStack(alignment: .bottom, spacing: 16) {
                Artwork(url: player.current?.artwork, cornerRadius: 4)
                    .frame(width: 150, height: 150)
                    .modifier(ArtworkGestures(onLongPress: onLongPress))
                VStack(alignment: .leading, spacing: 6) {
                    Text("BY").font(.caption.weight(.bold)).foregroundStyle(.secondary).kerning(2)
                    Text(player.current?.artist ?? "").font(.title2.weight(.semibold).italic()).lineLimit(2)
                    if let album = player.current?.album {
                        Text(album.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).kerning(1.5).lineLimit(1)
                    }
                }
            }
            Rectangle().fill(.primary).frame(height: 2)
            Spacer()
            SeekBar()
            PlayerControls()
                .padding(.bottom, 16)
        }
        .padding(.horizontal, 26)
    }
}

struct CanvasStyle: View {
    var onLongPress: () -> Void
    @Environment(MusicPlayer.self) private var player
    var body: some View {
        VStack {
            Spacer()
                .contentShape(Rectangle())
                .modifier(ArtworkGestures(onLongPress: onLongPress))
            VStack(spacing: 18) {
                TitleBlock()
                SeekBar()
                PlayerControls()
            }
            .padding(22)
            .glassEffect(.regular, in: .rect(cornerRadius: 34))
            .padding(.horizontal, 14).padding(.bottom, 12)
        }
    }
}

struct BentoStyle: View {
    var onLongPress: () -> Void
    @Binding var showLyrics: Bool
    @Binding var showQueue: Bool
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Artwork(url: player.current?.largeArtwork ?? player.current?.artwork, cornerRadius: 26)
                    .aspectRatio(1, contentMode: .fit)
                    .modifier(ArtworkGestures(onLongPress: onLongPress))
                VStack(spacing: 12) {
                    tile {
                        Button { showQueue = true } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Up next", systemImage: "list.bullet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(player.upNext.first?.title ?? String(localized: "Radio")).font(.subheadline.weight(.semibold)).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }.buttonStyle(.plain)
                    }
                    tile {
                        Button { showLyrics = true } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("Lyrics", systemImage: "quote.bubble").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text("Tap to sing along").font(.subheadline.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }.buttonStyle(.plain)
                    }
                }
                .frame(width: 130)
            }
            tile { TitleBlock() }.frame(height: 100)
            tile { SeekBar() }.frame(height: 76)
            tile { PlayerControls(compact: true) }.frame(height: 100)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func tile<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content().padding(14).frame(maxWidth: .infinity, maxHeight: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }
}

struct DialStyle: View {
    var onLongPress: () -> Void
    @Environment(MusicPlayer.self) private var player
    @State private var spin: Double = 0

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(.primary.opacity(0.12), lineWidth: 8)
                DialProgress()
                TimelineView(.animation(paused: !player.isPlaying)) { context in
                    Artwork(url: player.current?.artwork, cornerRadius: 1000)
                        .overlay(Circle().fill(Color(.systemBackground)).frame(width: 36, height: 36))
                        .rotationEffect(.degrees(player.isPlaying ? context.date.timeIntervalSinceReferenceDate * 20 : 0))
                        .padding(18)
                }
                .modifier(ArtworkGestures(onLongPress: onLongPress))
            }
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 36)
            Spacer(minLength: 0)
            TitleBlock(alignment: .center)
            DialTimes()
            PlayerControls().padding(.bottom, 16)
        }
        .padding(.horizontal, 26)
    }
}

/// The dial's ring and times read the play position on their own, so the rest of the Dial style
/// (the spinning artwork, the title, the controls) doesn't redraw four times a second.
private struct DialProgress: View {
    @Environment(MusicPlayer.self) private var player
    var body: some View {
        Circle().trim(from: 0, to: player.duration > 0 ? player.currentTime / player.duration : 0)
            .stroke(.tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
            .rotationEffect(.degrees(-90))
            .animation(.linear(duration: 0.25), value: player.currentTime)
    }
}

private struct DialTimes: View {
    @Environment(MusicPlayer.self) private var player
    var body: some View {
        HStack {
            Text(player.currentTime.formattedDuration)
            Spacer()
            Text(player.duration.formattedDuration)
        }
        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
    }
}
