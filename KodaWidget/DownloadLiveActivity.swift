import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Video downloads on the Lock Screen and in the Dynamic Island. While there's an estimated end,
/// progress and time left run on the clock, as Koda can't send updates while it's suspended.
struct DownloadLiveActivity: Widget {
    static let url = URL(string: "koda://downloads")

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreen(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color(red: 0.12, green: 0.1, blue: 0.2).opacity(0.85))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(Self.url)
        } dynamicIsland: { context in
            let state = context.state
            let isStale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DownloadThumbnail(state: state, cornerRadius: 10)
                        .frame(width: 64, height: 36)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    DownloadRing(state: state, isStale: isStale, lineWidth: 4)
                        .frame(width: 36, height: 36)
                        .frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.title).font(.headline).lineLimit(1)
                        DownloadStatusLine(state: state)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DownloadProgress(state: state, isStale: isStale)
                        .padding(.top, 4)
                        // Clear of the island's rounded corners.
                        .padding(.horizontal, 6)
                }
            } compactLeading: {
                DownloadRing(state: state, isStale: isStale, lineWidth: 2.5)
                    .frame(width: 22, height: 22)
            } compactTrailing: {
                DownloadCompactTrailing(state: state)
            } minimal: {
                DownloadRing(state: state, isStale: isStale, lineWidth: 2.5)
                    .frame(width: 22, height: 22)
            }
            .widgetURL(Self.url)
            .keylineTint(Color(red: 0.4, green: 0.31, blue: 0.64))
        }
    }
}

private let downloadTint = Color(red: 0.62, green: 0.53, blue: 1)

struct DownloadLockScreen: View {
    var state: DownloadActivityAttributes.ContentState
    var isStale: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                DownloadThumbnail(state: state, cornerRadius: 10)
                    .frame(width: 80, height: 45)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title).font(.headline).lineLimit(1).foregroundStyle(.white)
                    DownloadStatusLine(state: state)
                        .font(.subheadline).lineLimit(1).foregroundStyle(.white.opacity(0.75))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                DownloadRing(state: state, isStale: isStale, lineWidth: 3.5)
                    .frame(width: 34, height: 34)
            }
            DownloadProgress(state: state, isStale: isStale)
        }
        .padding(16)
    }
}

/// "Downloading 2 videos · 720p", "Waiting to continue", "Downloaded", "Download failed".
struct DownloadStatusLine: View {
    var state: DownloadActivityAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .downloading:
            Text("\(Text("Downloading \(state.activeCount) videos")) · \(quality)")
        case .waiting:
            Text("\(Text("Waiting to continue")) · \(quality)")
        case .finished:
            if state.finishedCount > 1 { Text("\(state.finishedCount) videos downloaded") } else { Text("Downloaded") }
        case .failed:
            if state.failedCount > 1 { Text("\(state.failedCount) downloads failed") } else { Text("Download failed") }
        }
    }

    private var quality: Text { state.isAudioOnly ? Text("Audio only") : Text(verbatim: state.quality) }
}

/// The bar, and the size with the time left (or the percentage when there's no estimate).
struct DownloadProgress: View {
    var state: DownloadActivityAttributes.ContentState
    var isStale: Bool

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let range = running {
                    ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                } else {
                    ProgressView(value: shownFraction)
                }
            }
            .progressViewStyle(.linear)
            .tint(state.phase == .failed ? .orange : downloadTint)
            HStack {
                if state.bytesTotal > 0 {
                    if running != nil || state.phase == .finished {
                        Text(verbatim: Self.bytes(state.bytesTotal))
                    } else {
                        Text("\(Self.bytes(state.bytesDone)) of \(Self.bytes(state.bytesTotal))")
                    }
                }
                Spacer(minLength: 8)
                if let range = running {
                    Text("\(Text(timerInterval: state.capturedAt...range.upperBound, countsDown: true)) left")
                        .multilineTextAlignment(.trailing)
                } else if isStale && state.phase == .downloading {
                    Text("Finishing…")
                } else if state.phase == .downloading || state.phase == .waiting {
                    Text(state.fraction, format: .percent.precision(.fractionLength(0)))
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var running: ClosedRange<Date>? { isStale ? nil : state.timerRange }
    private var shownFraction: Double { state.phase == .finished ? 1 : min(max(state.fraction, 0), 1) }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

/// A ring around a download arrow (a tick once done, a warning on failure).
struct DownloadRing: View {
    var state: DownloadActivityAttributes.ContentState
    var isStale: Bool
    var lineWidth: CGFloat

    var body: some View {
        switch state.phase {
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .resizable().scaledToFit()
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .resizable().scaledToFit()
                .foregroundStyle(.orange)
        case .downloading, .waiting:
            ZStack {
                Group {
                    if !isStale, let range = state.timerRange {
                        ProgressView(timerInterval: range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
                    } else {
                        ProgressView(value: min(max(state.fraction, 0), 1))
                    }
                }
                .progressViewStyle(.circular)
                .tint(downloadTint)
                Image(systemName: state.phase == .waiting ? "pause.fill" : "arrow.down")
                    .font(.system(size: lineWidth * 3, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct DownloadCompactTrailing: View {
    var state: DownloadActivityAttributes.ContentState

    var body: some View {
        Group {
            switch state.phase {
            case .downloading, .waiting:
                Text(state.fraction, format: .percent.precision(.fractionLength(0)))
            case .finished:
                Image(systemName: "checkmark")
            case .failed:
                Image(systemName: "exclamationmark")
            }
        }
        .font(.footnote.weight(.semibold).monospacedDigit())
        .foregroundStyle(downloadTint)
    }
}

/// The small 16:9 thumbnail copy in the App Group; a gradient until Koda has written this video's.
struct DownloadThumbnail: View {
    var state: DownloadActivityAttributes.ContentState
    var cornerRadius: CGFloat

    var body: some View {
        Group {
            if state.hasArtwork, let url = NowPlayingSnapshot.downloadArtworkURL,
               let image = UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 200, height: 112)) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: state.isAudioOnly ? "waveform" : "play.rectangle.fill")
                        .font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
