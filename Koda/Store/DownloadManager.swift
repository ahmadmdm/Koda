import Foundation
import Observation

/// Song downloads for offline playback. googlevideo paces open-ended requests to
/// the media bitrate, so files are fetched in bounded 4 MB ranges, as Koda does.
@MainActor
@Observable
final class DownloadManager {
    static let shared = DownloadManager()

    enum State: Equatable { case queued, downloading(Double), failed(String) }

    var active: [String: State] = [:]
    var pending: [Song] = []
    /// Each download's task, with a token so a finished task never clears a newer one for the same song.
    @ObservationIgnored private var tasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var library: LibraryStore { .shared }

    func isDownloaded(_ id: String) -> Bool { library.data.downloads.contains { $0.song.id == id } }

    func localURL(for id: String) -> URL? {
        guard let d = library.data.downloads.first(where: { $0.song.id == id }) else { return nil }
        let url = Self.directory.appendingPathComponent(d.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(_ songs: [Song]) {
        for song in songs where !song.isLocal && !isDownloaded(song.id) && active[song.id] == nil {
            active[song.id] = .queued
            pending.append(song)
            let token = UUID()
            tasks[song.id] = (token, Task { await self.run(song, token: token) })
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.task.cancel(); tasks[id] = nil
        active[id] = nil; pending.removeAll { $0.id == id }
    }

    func delete(_ id: String) {
        if let d = library.data.downloads.first(where: { $0.song.id == id }) {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(d.fileName))
        }
        library.data.downloads.removeAll { $0.song.id == id }
    }

    func retry(_ song: Song) { active[song.id] = nil; pending.removeAll { $0.id == song.id }; download([song]) }

    var totalBytes: Int64 { library.data.downloads.reduce(0) { $0 + $1.bytes } }

    private func run(_ song: Song, token: UUID) async {
        let fileName = "\(song.id).m4a"
        let target = Self.directory.appendingPathComponent(fileName)
        do {
            let quality = UserDefaults.standard.string(forKey: "downloadQuality") ?? "high"
            let info = try await InnerTube.shared.player(videoId: song.id)
            guard let url = quality == "saver" ? (info.lowAudioURL ?? info.audioURL) : info.audioURL else { throw InnerTubeError.noStream }
            let bytes = try await Self.fetchRanged(url, userAgent: InnerTube.userAgent(for: url), progress: { progress in
                Task { @MainActor in if self.active[song.id] != nil { self.active[song.id] = .downloading(progress) } }
            }, to: target)
            var saved = song
            if saved.duration == nil, info.duration > 0 { saved.duration = Int(info.duration) }
            library.data.downloads.removeAll { $0.song.id == song.id }
            library.data.downloads.insert(DownloadedSong(song: saved, fileName: fileName, bytes: bytes, date: .now), at: 0)
            active[song.id] = nil
            pending.removeAll { $0.id == song.id }
        } catch {
            // A cancelled request throws URLError.cancelled rather than CancellationError.
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            if cancelled { try? FileManager.default.removeItem(at: target.appendingPathExtension("part")) }
            // A newer download of this song (after a cancel and a new start) owns its state now.
            guard tasks[song.id]?.token == token else { return }
            active[song.id] = cancelled ? nil : .failed(error.localizedDescription)
        }
        if tasks[song.id]?.token == token { tasks[song.id] = nil }
    }

    nonisolated static func fetchRanged(_ url: URL, userAgent: String = InnerTube.visionUA, progress: @Sendable @escaping (Double) -> Void, to target: URL) async throws -> Int64 {
        let partial = target.appendingPathExtension("part")
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        let chunk: Int64 = 4 * 1024 * 1024
        var offset: Int64 = 0
        var total: Int64? = nil
        repeat {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("bytes=\(offset)-\(offset + chunk - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
                throw InnerTubeError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            if total == nil, let range = http.value(forHTTPHeaderField: "Content-Range"), let size = range.split(separator: "/").last.flatMap({ Int64($0) }) {
                total = size
            }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            if http.statusCode == 200 { total = offset }
            progress(Double(offset) / Double(max(total ?? offset, 1)))
            if data.isEmpty { break }
        } while offset < (total ?? 0)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        return offset
    }
}
