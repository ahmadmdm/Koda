import ActivityKit
import Foundation

/// The music player's Live Activity, on the Lock Screen and in the Dynamic Island. It also shows the
/// playing video while the video player owns Now Playing (`isVideo`; `songId` is then the video's id
/// and `artist` its channel), with the thumbnail in `NowPlayingSnapshot.videoArtworkURL`.
/// The artwork isn't part of the state (payloads must stay under 4 KB): the widget reads the small
/// copy the app writes to the App Group (`NowPlayingSnapshot.artworkURL`) once `artworkSongId`
/// says it belongs to the song shown.
nonisolated struct NowPlayingActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        var songId: String
        var title: String
        var artist: String
        var isPlaying: Bool
        var elapsed: Double
        var duration: Double
        var capturedAt: Date
        var artworkSongId: String?
        /// Optional, so states from builds before video support still decode.
        var isVideo: Bool? = nil
        /// Whether next has something to play; nil (music) always shows it.
        var hasNext: Bool? = nil

        var showsVideo: Bool { isVideo == true }
        var showsNext: Bool { hasNext ?? true }

        var hasArtwork: Bool { artworkSongId == songId }
        /// When the song started, measured on the clock, so progress runs without updates.
        var startDate: Date { capturedAt.addingTimeInterval(-elapsed) }
        var endDate: Date { startDate.addingTimeInterval(max(duration, 1)) }
        var progress: Double { duration > 0 ? min(max(elapsed / duration, 0), 1) : 0 }
    }
}
