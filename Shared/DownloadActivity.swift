import ActivityKit
import Foundation

/// Video downloads on the Lock Screen and in the Dynamic Island: one activity for every download
/// running at once. The downloads carry on in the system's background session while Koda is suspended
/// and can't send updates, so the state holds an estimated end: the widget runs progress and time left
/// on the clock from it, and falls back to the last fraction when there is none.
/// The thumbnail isn't part of the state (payloads stay under 4 KB): the widget reads the small copy
/// in `downloadArtworkURL` once `artworkVideoId` says it belongs to the video shown.
nonisolated struct DownloadActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        nonisolated enum Phase: String, Codable, Hashable, Sendable {
            case downloading
            /// Nothing has arrived for a while (no network, or an audio-only download Koda has to be open for).
            case waiting
            case finished
            case failed
        }

        var phase: Phase
        /// The video shown: the oldest download still running, or the last one to finish.
        var videoId: String
        var title: String
        /// "720p", or "Audio" for audio only.
        var quality: String
        /// Downloads still running.
        var activeCount: Int
        /// Downloads that finished, and that failed, since the activity started.
        var finishedCount: Int
        var failedCount: Int
        /// All of the activity's downloads together, finished ones included.
        var fraction: Double
        var bytesDone: Int64
        var bytesTotal: Int64
        /// When `fraction` was measured, and when everything should be done at the rate measured then.
        var capturedAt: Date
        var estimatedEnd: Date?
        /// The video whose thumbnail is in the App Group file.
        var artworkVideoId: String?

        var hasArtwork: Bool { artworkVideoId == videoId }
        var isAudioOnly: Bool { quality == "Audio" }

        /// Progress that runs on the clock: a range whose position at `capturedAt` is `fraction` and
        /// that ends at the estimated end. Nil without an estimate.
        var timerRange: ClosedRange<Date>? {
            guard phase == .downloading, let end = estimatedEnd, end > capturedAt else { return nil }
            let remaining = end.timeIntervalSince(capturedAt)
            let done = min(max(fraction, 0), 0.99)
            let start = capturedAt.addingTimeInterval(-remaining * done / (1 - done))
            return start...end
        }
    }
}

extension NowPlayingSnapshot {
    /// The downloading video's thumbnail for the download Live Activity, apart from the playing video's.
    nonisolated static var downloadArtworkURL: URL? { containerURL?.appendingPathComponent("download-artwork.jpg") }
}
