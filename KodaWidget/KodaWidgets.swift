import AppIntents
import SwiftUI
import WidgetKit

@main
struct KodaWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        NowPlayingLiveActivity()
        DownloadLiveActivity()
        PlayPauseControl()
    }
}

// MARK: Timeline

struct NowPlayingEntry: TimelineEntry {
    var date: Date
    var snapshot: NowPlayingSnapshot?
    var artwork: UIImage?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: .placeholder, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(current() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        let entry = current() ?? NowPlayingEntry(date: .now, snapshot: nil, artwork: nil)
        var entries = [entry]
        // While a song plays, show it stopped once it should have ended: the app reloads on every
        // change, so a song still "playing" past its end means the app was closed.
        if let snapshot = entry.snapshot, snapshot.isPlaying {
            entries.append(NowPlayingEntry(date: snapshot.endDate, snapshot: Self.stopped(snapshot), artwork: entry.artwork))
        }
        completion(Timeline(entries: entries, policy: .after(.now.addingTimeInterval(3600))))
    }

    private func current() -> NowPlayingEntry? {
        guard var snapshot = NowPlayingSnapshot.load() else { return nil }
        if snapshot.isPlaying, Date.now > snapshot.endDate { snapshot = Self.stopped(snapshot) }
        // Only the artwork of this song: the file may still hold the previous song's.
        let artwork = snapshot.hasArtwork ? NowPlayingSnapshot.artworkURL.flatMap { UIImage(contentsOfFile: $0.path) } : nil
        return NowPlayingEntry(date: .now, snapshot: snapshot, artwork: artwork)
    }

    private static func stopped(_ snapshot: NowPlayingSnapshot) -> NowPlayingSnapshot {
        var stopped = snapshot
        stopped.isPlaying = false
        stopped.elapsed = snapshot.duration
        return stopped
    }
}

// MARK: Widget

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KodaNowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("The song playing in Koda, with controls and what comes next.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
        .contentMarginsDisabled()
    }
}

struct NowPlayingWidgetView: View {
    var entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .systemSmall: SmallView(snapshot: snapshot, artwork: entry.artwork)
                case .systemMedium: MediumView(snapshot: snapshot, artwork: entry.artwork)
                case .systemLarge: LargeView(snapshot: snapshot, artwork: entry.artwork)
                case .accessoryRectangular: RectangularView(snapshot: snapshot)
                case .accessoryCircular: CircularView(snapshot: snapshot)
                default: Text("♪ \(snapshot.title) — \(snapshot.artist)")
                }
            } else {
                EmptyStateView()
            }
        }
        .containerBackground(for: .widget) {
            WidgetBackground(artwork: entry.artwork, tint: entry.snapshot?.tintColor, isAccessory: family.isAccessory)
        }
        .widgetURL(URL(string: "koda://nowplaying"))
    }
}

// MARK: Pieces

private extension WidgetFamily {
    var isAccessory: Bool { [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(self) }
}

extension NowPlayingSnapshot {
    var tintColor: Color? {
        guard let hex = tintHex, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

struct WidgetBackground: View {
    var artwork: UIImage?
    var tint: Color?
    var isAccessory: Bool

    var body: some View {
        if isAccessory {
            Color.clear
        } else {
            ZStack {
                (tint ?? Color(red: 0.25, green: 0.2, blue: 0.45))
                if let artwork {
                    Image(uiImage: artwork).resizable().scaledToFill()
                        .blur(radius: 28).scaleEffect(1.4).opacity(0.85)
                }
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            }
        }
    }
}

struct ArtworkTile: View {
    var artwork: UIImage?
    var cornerRadius: CGFloat = 14

    var body: some View {
        Group {
            if let artwork {
                Image(uiImage: artwork).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }
}

struct SongProgress: View {
    var snapshot: NowPlayingSnapshot

    var body: some View {
        Group {
            if snapshot.isPlaying {
                ProgressView(timerInterval: snapshot.startDate...snapshot.endDate, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: snapshot.progress)
            }
        }
        .progressViewStyle(.linear)
        .tint(.white)
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct ControlButton: View {
    var intent: any AppIntent
    var systemImage: String
    var size: CGFloat = 34
    var prominent = false

    var body: some View {
        Button(intent: intent) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .frame(width: size, height: size)
                .background(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.18)), in: Circle())
                .foregroundStyle(prominent ? Color.black : .white)
        }
        .buttonStyle(.plain)
        .widgetAccentable(prominent)
    }
}

struct TransportControls: View {
    var snapshot: NowPlayingSnapshot
    var size: CGFloat = 34

    var body: some View {
        HStack(spacing: 10) {
            ControlButton(intent: PreviousTrackIntent(), systemImage: "backward.fill", size: size)
            ControlButton(intent: TogglePlaybackIntent(), systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill", size: size * 1.18, prominent: true)
            ControlButton(intent: NextTrackIntent(), systemImage: "forward.fill", size: size)
        }
        // Transport keeps its direction in right-to-left languages, as in Apple Music.
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct TitleLines: View {
    var snapshot: NowPlayingSnapshot
    var titleFont: Font = .headline

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.title).font(titleFont).lineLimit(2).foregroundStyle(.white)
            Text(snapshot.artist).font(.subheadline).lineLimit(1).foregroundStyle(.white.opacity(0.75))
        }
    }
}

// MARK: Families

struct SmallView: View {
    var snapshot: NowPlayingSnapshot
    var artwork: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ArtworkTile(artwork: artwork, cornerRadius: 12).frame(width: 64, height: 64)
                Spacer(minLength: 0)
                ControlButton(intent: TogglePlaybackIntent(), systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill", size: 38, prominent: true)
            }
            Spacer(minLength: 0)
            TitleLines(snapshot: snapshot, titleFont: .subheadline.weight(.semibold))
            SongProgress(snapshot: snapshot)
        }
        .padding(14)
    }
}

struct MediumView: View {
    var snapshot: NowPlayingSnapshot
    var artwork: UIImage?

    var body: some View {
        HStack(spacing: 14) {
            ArtworkTile(artwork: artwork, cornerRadius: 16).aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    TitleLines(snapshot: snapshot)
                    Spacer(minLength: 4)
                    Button(intent: ToggleLikeIntent()) {
                        Image(systemName: snapshot.isLiked ? "heart.fill" : "heart")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(snapshot.isLiked ? .pink : .white.opacity(0.8))
                            // A bare symbol is too small to hit with a finger.
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(-8)
                }
                Spacer(minLength: 0)
                SongProgress(snapshot: snapshot)
                TransportControls(snapshot: snapshot, size: 32)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(14)
    }
}

struct LargeView: View {
    var snapshot: NowPlayingSnapshot
    var artwork: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                ArtworkTile(artwork: artwork, cornerRadius: 18).frame(width: 118, height: 118)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Koda", systemImage: "waveform").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                    TitleLines(snapshot: snapshot, titleFont: .title3.weight(.bold))
                    Spacer(minLength: 0)
                }
            }
            SongProgress(snapshot: snapshot)
            TransportControls(snapshot: snapshot, size: 40).frame(maxWidth: .infinity)
            if !snapshot.upNext.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6)).textCase(.uppercase)
                    ForEach(Array(snapshot.upNext.prefix(3).enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.caption.monospacedDigit().weight(.bold)).foregroundStyle(.white.opacity(0.5)).frame(width: 14)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.title).font(.footnote.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
                                Text(item.artist).font(.caption2).lineLimit(1).foregroundStyle(.white.opacity(0.65))
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(16)
    }
}

struct RectangularView: View {
    var snapshot: NowPlayingSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(snapshot.title, systemImage: snapshot.isPlaying ? "waveform" : "pause.fill")
                .font(.headline).lineLimit(1).widgetAccentable()
            Text(snapshot.artist).font(.caption).lineLimit(1)
            SongProgress(snapshot: snapshot)
        }
    }
}

struct CircularView: View {
    var snapshot: NowPlayingSnapshot
    var body: some View {
        Button(intent: TogglePlaybackIntent()) {
            Gauge(value: snapshot.progress) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        }
        .buttonStyle(.plain)
    }
}

struct EmptyStateView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        if family.isAccessory {
            Label("Koda", systemImage: "music.note")
        } else {
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 36)).foregroundStyle(.white)
                Text("Nothing playing").font(.headline).foregroundStyle(.white)
                Text("Open Koda to start the music.").font(.caption).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
            }
            .padding()
        }
    }
}

// MARK: Control Center

struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.koda.ios.playpause") {
            ControlWidgetButton(action: TogglePlaybackIntent()) {
                Label("Koda", systemImage: "playpause.fill")
            }
        }
        .displayName("Play or Pause")
        .description("Plays or pauses Koda.")
    }
}

#Preview(as: .systemMedium) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry(date: .now, snapshot: .placeholder, artwork: nil)
}
