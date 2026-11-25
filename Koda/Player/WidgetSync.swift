import UIKit
import WidgetKit

/// Keeps the widgets' copy of the now-playing state current, at most every half second.
@MainActor
enum WidgetSync {
    private static var pending: Task<Void, Never>?
    private static var lastKey = ""
    private static var lastArtworkId = ""

    static func update(_ player: MusicPlayer) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write(player)
            LiveActivitySync.update(player)
        }
    }

    private static func write(_ player: MusicPlayer) {
        guard let song = player.current else { return }
        let snapshot = NowPlayingSnapshot(
            title: song.title, artist: song.artist, album: song.album,
            isPlaying: player.isPlaying, elapsed: player.currentTime, duration: player.duration,
            capturedAt: .now, isLiked: LibraryStore.shared.isLiked(song),
            upNext: player.upNext.prefix(4).map { .init(title: $0.title, artist: $0.artist) },
            tintHex: nil)
        snapshot.save()
        // Reload only when something a widget shows has changed, not on every tick.
        let key = "\(song.id)|\(player.isPlaying)|\(snapshot.isLiked)|\(snapshot.upNext.map(\.title))|\(Int(player.duration))"
        if key != lastKey {
            lastKey = key
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func saveArtwork(_ image: UIImage, songId: String) {
        guard songId != lastArtworkId, let url = NowPlayingSnapshot.artworkURL else { return }
        lastArtworkId = songId
        let side: CGFloat = 360
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let scaled = renderer.image { _ in
            let scale = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
        try? scaled.jpegData(compressionQuality: 0.85)?.write(to: url, options: .atomic)
        LiveActivitySync.artworkSaved(songId: songId)
        lastKey = ""
        WidgetCenter.shared.reloadAllTimelines()
    }
}
