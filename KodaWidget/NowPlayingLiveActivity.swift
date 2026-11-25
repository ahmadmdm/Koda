import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// The music Live Activity: Lock Screen banner and Dynamic Island (compact, minimal, expanded).
/// Play/pause and next are the app's `AudioPlaybackIntent`s, which run in the app's process.
struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NowPlayingActivityAttributes.self) { context in
            LiveActivityLockScreen(state: context.state)
                .activityBackgroundTint(Color(red: 0.12, green: 0.1, blue: 0.2).opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(URL(string: "koda://nowplaying"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    LiveActivityArtwork(state: state, cornerRadius: 12)
                        .frame(width: 52, height: 52)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LiveActivityControls(state: state, size: 36)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.headline).lineLimit(1)
                        Text(state.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    LiveActivityProgress(state: state)
                        .padding(.top, 4)
                }
            } compactLeading: {
                LiveActivityArtwork(state: state, cornerRadius: 6, maxPixels: 72)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
            } minimal: {
                LiveActivityArtwork(state: state, cornerRadius: 12, maxPixels: 72)
                    .frame(width: 24, height: 24)
            }
            .widgetURL(URL(string: "koda://nowplaying"))
            .keylineTint(Color(red: 0.4, green: 0.31, blue: 0.64))
        }
    }
}

struct LiveActivityLockScreen: View {
    var state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                LiveActivityArtwork(state: state, cornerRadius: 12)
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(1).foregroundStyle(.white)
                    Text(state.artist).font(.subheadline).lineLimit(1).foregroundStyle(.white.opacity(0.75))
                }
                Spacer(minLength: 4)
                LiveActivityControls(state: state, size: 38)
            }
            LiveActivityProgress(state: state)
        }
        .padding(16)
    }
}

/// The small artwork copy in the App Group; a gradient until the app has written this song's.
struct LiveActivityArtwork: View {
    var state: NowPlayingActivityAttributes.ContentState
    var cornerRadius: CGFloat
    /// Largest side in pixels. The Dynamic Island draws a blank placeholder for images over its
    /// small memory budget, so compact and minimal pass a tiny size.
    var maxPixels: CGFloat = 200

    var body: some View {
        Group {
            if state.hasArtwork, let url = NowPlayingSnapshot.artworkURL, let image = UIImage(contentsOfFile: url.path)?
                .preparingThumbnail(of: CGSize(width: maxPixels, height: maxPixels)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct LiveActivityControls: View {
    var state: NowPlayingActivityAttributes.ContentState
    var size: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            ControlButton(intent: TogglePlaybackIntent(), systemImage: state.isPlaying ? "pause.fill" : "play.fill",
                          size: size, prominent: true)
            ControlButton(intent: NextTrackIntent(), systemImage: "forward.fill", size: size * 0.86)
        }
        // Transport keeps its direction in right-to-left languages, as in Apple Music.
        .environment(\.layoutDirection, .leftToRight)
    }
}

struct LiveActivityProgress: View {
    var state: NowPlayingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if state.isPlaying {
                    Text(timerInterval: state.startDate...state.endDate, countsDown: false)
                } else {
                    Text(Self.format(state.elapsed))
                }
            }
            .frame(width: 44, alignment: .leading)
            Group {
                if state.isPlaying {
                    ProgressView(timerInterval: state.startDate...state.endDate, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: state.progress)
                }
            }
            .progressViewStyle(.linear)
            .tint(.white)
            Text(Self.format(state.duration))
                .frame(width: 44, alignment: .trailing)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white.opacity(0.7))
        .environment(\.layoutDirection, .leftToRight)
    }

    static func format(_ seconds: Double) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
