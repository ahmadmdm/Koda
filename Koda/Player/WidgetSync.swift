import UIKit
import WidgetKit

/// Keeps the widgets' copy of the now-playing state current, at most every half second.
@MainActor
enum WidgetSync {
    private static var pending: Task<Void, Never>?
    private static var lastKey = ""
    private static var artworkWrite: Task<Void, Never>?
    /// The song whose artwork is in the App Group, carried over from the previous run's snapshot.
    private static var lastArtworkId = NowPlayingSnapshot.load()?.artworkSongId ?? ""
    /// The song whose artwork the file holds now; `lastArtworkId` runs ahead of it while a write is under way.
    private static var writtenArtworkId = lastArtworkId

    static func update(_ player: MusicPlayer) {
        pending?.cancel()
        // The half-second wait would outlast the app once a pause stops its audio.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Widget snapshot")
        pending = Task {
            defer { UIApplication.shared.endBackgroundTask(background) }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write(player)
            LiveActivitySync.update(player)
        }
    }

    private static func write(_ player: MusicPlayer) {
        guard let song = player.current else {
            // Nothing to play: never leave a widget showing the last song as playing.
            if var stale = NowPlayingSnapshot.load(), stale.isPlaying {
                stale.isPlaying = false
                stale.save()
                lastKey = ""
                WidgetCenter.shared.reloadAllTimelines()
            }
            return
        }
        let snapshot = NowPlayingSnapshot(
            title: song.title, artist: song.artist, album: song.album,
            isPlaying: player.isPlaying, elapsed: player.currentTime, duration: player.duration,
            capturedAt: .now, isLiked: LibraryStore.shared.isLiked(song),
            upNext: player.upNext.prefix(4).map { .init(title: $0.title, artist: $0.artist) },
            tintHex: nil, songId: song.id, artworkSongId: writtenArtworkId.isEmpty ? nil : writtenArtworkId)
        snapshot.save()
        // Reload only when something a widget shows has changed, not on every tick.
        let key = "\(song.id)|\(player.isPlaying)|\(snapshot.isLiked)|\(snapshot.upNext.map(\.title))|\(Int(player.duration))|\(writtenArtworkId)"
        if key != lastKey {
            lastKey = key
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    static func saveArtwork(_ image: UIImage, songId: String) {
        guard songId != lastArtworkId, let url = NowPlayingSnapshot.artworkURL else { return }
        lastArtworkId = songId
        let previous = artworkWrite
        artworkWrite = Task {
            // One write at a time, in order, so the file always ends with the newest song's artwork.
            await previous?.value
            // Scaling, JPEG encoding and the file write take a frame or more: do them off the main thread.
            await writeArtwork(image, to: url)
            writtenArtworkId = songId
            // Another song's artwork may have been saved meanwhile; it reports for itself.
            guard lastArtworkId == songId else { return }
            LiveActivitySync.artworkSaved(songId: songId)
            // Write the snapshot now, so it says whose artwork the file holds (this reloads the widgets).
            write(MusicPlayer.shared)
        }
    }

    @concurrent
    private nonisolated static func writeArtwork(_ image: UIImage, to url: URL) async {
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
    }
}
