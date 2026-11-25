import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

/// Audio files on this iPhone: imported from Files, or dropped into Koda's Documents/Music folder
/// through the Files app or Finder. Each becomes a `Song` with the id `local:<file name>`, so it plays
/// through the same queue as YouTube songs. Tags (title, artist, album, artwork, length) are read once
/// with AVFoundation and cached by file size and date.
@MainActor
@Observable
final class LocalMusicLibrary {
    static let shared = LocalMusicLibrary()

    nonisolated static let idPrefix = "local:"
    nonisolated static let fileExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif"]

    static var contentTypes: [UTType] {
        [.mp3, .mpeg4Audio, UTType("public.aac-audio"), .wav, UTType("org.xiph.flac"), .aiff].compactMap { $0 } + [.audio]
    }

    private(set) var songs: [Song] = []
    private(set) var isScanning = false

    @ObservationIgnored private var index: [String: Entry] = [:]
    /// A rescan was asked for while one ran: files may have arrived after it listed the folder.
    @ObservationIgnored private var rescanRequested = false

    nonisolated struct Entry: Codable, Sendable {
        var song: Song
        var size: Int64
        var modified: Date
    }

    nonisolated static let directory: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static let artworkDirectory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalArtwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private nonisolated static let indexURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local-music.json")
    }()

    init() {
        if let raw = try? Data(contentsOf: Self.indexURL), let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) {
            index = decoded
            songs = Self.sorted(decoded.values.map(\.song))
        }
    }

    // MARK: Paths

    nonisolated static func id(forFileName name: String) -> String { idPrefix + name }

    nonisolated static func fileName(for id: String) -> String? {
        guard id.hasPrefix(idPrefix) else { return nil }
        let name = String(id.dropFirst(idPrefix.count))
        guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return nil }
        return name
    }

    /// The file behind a `local:` id, if it is still there.
    nonisolated static func fileURL(for id: String) -> URL? {
        guard let name = fileName(for: id) else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Resolved on every call, since the app container's path can change between installs.
    nonisolated static func artworkURL(for id: String) -> URL? {
        guard let name = fileName(for: id) else { return nil }
        let url = artworkDirectory.appendingPathComponent(artworkName(name))
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated static func artworkName(_ fileName: String) -> String {
        let safe = fileName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return "\(safe.prefix(80))-\(UInt(bitPattern: stableHash(fileName))).jpg"
    }

    /// FNV-1a, so artwork names stay the same across launches (`hashValue` is seeded per process).
    private nonisolated static func stableHash(_ s: String) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(truncatingIfNeeded: h)
    }

    // MARK: Scanning

    /// Matches the folder: adds new files, re-reads changed ones and forgets removed ones.
    func rescan() async {
        guard !isScanning else { rescanRequested = true; return }
        isScanning = true
        defer { isScanning = false }
        repeat {
            rescanRequested = false
            await scan()
        } while rescanRequested
    }

    private func scan() async {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? fm.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        var next: [String: Entry] = [:]
        for file in files where Self.fileExtensions.contains(file.pathExtension.lowercased()) {
            let values = try? file.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile != false else { continue }
            let name = file.lastPathComponent
            let size = Int64(values?.fileSize ?? 0)
            let modified = values?.contentModificationDate ?? .distantPast
            if let known = index[name], known.size == size, known.modified == modified {
                next[name] = known
            } else {
                try? fm.removeItem(at: Self.artworkDirectory.appendingPathComponent(Self.artworkName(name)))
                let song = await Self.readSong(at: file)
                next[name] = Entry(song: song, size: size, modified: modified)
            }
        }
        for gone in Set(index.keys).subtracting(next.keys) {
            try? fm.removeItem(at: Self.artworkDirectory.appendingPathComponent(Self.artworkName(gone)))
        }
        index = next
        songs = Self.sorted(next.values.map(\.song))
        save()
    }

    /// Copies picked files into Documents/Music. Returns how many were added.
    @discardableResult
    func importFiles(_ urls: [URL]) async -> Int {
        var added = 0
        for url in urls where Self.fileExtensions.contains(url.pathExtension.lowercased()) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let target = Self.uniqueTarget(for: url.lastPathComponent)
            if (try? FileManager.default.copyItem(at: url, to: target)) != nil { added += 1 }
        }
        await rescan()
        return added
    }

    func delete(_ song: Song) {
        guard let name = Self.fileName(for: song.id) else { return }
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(name))
        try? FileManager.default.removeItem(at: Self.artworkDirectory.appendingPathComponent(Self.artworkName(name)))
        index[name] = nil
        songs.removeAll { $0.id == song.id }
        save()
    }

    var totalBytes: Int64 { index.values.reduce(0) { $0 + $1.size } }

    private func save() {
        let snapshot = index
        let url = Self.indexURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private static func sorted(_ songs: [Song]) -> [Song] {
        songs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func uniqueTarget(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    // MARK: Metadata

    /// Reads the tags off the main actor; falls back to the file name ("Artist - Title" when it looks like one).
    @concurrent
    nonisolated static func readSong(at url: URL) async -> Song {
        let name = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        var title = stem
        var artist = ""
        let parts = stem.components(separatedBy: " - ")
        if parts.count >= 2 {
            artist = parts[0].trimmingCharacters(in: .whitespaces)
            title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        }
        var album: String?
        var duration: Int?
        let asset = AVURLAsset(url: url)
        if let (metadata, length) = try? await asset.load(.commonMetadata, .duration) {
            if length.seconds.isFinite, length.seconds > 0 { duration = Int(length.seconds.rounded()) }
            func string(_ id: AVMetadataIdentifier) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: id).first,
                      let value = try? await item.load(.stringValue) else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let t = await string(.commonIdentifierTitle) { title = t }
            if let a = await string(.commonIdentifierArtist) { artist = a }
            album = await string(.commonIdentifierAlbumName)
            if let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
               let data = try? await item.load(.dataValue), !data.isEmpty {
                try? data.write(to: artworkDirectory.appendingPathComponent(artworkName(name)), options: .atomic)
            }
        }
        let id = id(forFileName: name)
        return Song(id: id, title: title, artist: artist, album: album, duration: duration,
                    thumbnail: artworkURL(for: id)?.absoluteString)
    }
}
