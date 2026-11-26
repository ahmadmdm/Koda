import Foundation

/// The rules for resuming a video and for Continue watching, kept apart from the player so they
/// can be tested.
nonisolated enum WatchProgress {
    /// Less than this from the start is not worth resuming.
    static let minimumPosition: Double = 10
    /// Within this much of the end counts as watched.
    static let endMargin: Double = 20
    /// As does this share of the video.
    static let finishedFraction = 0.95
    /// How often the position is written while a video plays.
    static let saveInterval: Double = 10

    /// Where a video should start again, or nil to start from the beginning. A length of 0 means
    /// it is not known yet: the saved position is used as it is.
    static func resumePosition(saved: Double, duration: Double) -> Double? {
        guard saved.isFinite, saved > minimumPosition else { return nil }
        guard duration.isFinite, duration > 0 else { return saved }
        return saved < duration - endMargin && saved / duration < finishedFraction ? saved : nil
    }

    /// The video's length as far as the history knows it.
    static func duration(of entry: VideoEntry) -> Double {
        if let d = entry.duration, d.isFinite, d > 0 { return d }
        return Double(entry.video.durationText?.durationSeconds ?? 0)
    }

    /// Started, not finished, and with a title to show.
    static func isInProgress(_ entry: VideoEntry) -> Bool {
        guard !entry.video.isLive, !entry.video.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return resumePosition(saved: entry.position, duration: duration(of: entry)) != nil
    }

    /// Continue watching: the videos in progress, most recently watched first.
    static func continueWatching(_ history: [VideoEntry], limit: Int = 10) -> [VideoEntry] {
        Array(history.filter(isInProgress).sorted { $0.date > $1.date }.prefix(limit))
    }

    /// How much of the video has been watched, for the progress bar on its thumbnail.
    static func fraction(of entry: VideoEntry) -> Double? {
        let total = duration(of: entry)
        guard entry.position > 0, total > 0 else { return nil }
        return min(entry.position / total, 1)
    }

    /// "1:02:03" or "4:05", the way YouTube writes a length.
    static func durationText(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
