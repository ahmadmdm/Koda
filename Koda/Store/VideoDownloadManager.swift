import os
import AVFoundation
import CoreMedia
import Foundation
import Observation
import UIKit

/// A video kept on the device for offline playback.
nonisolated struct DownloadedVideo: Codable, Hashable, Identifiable, Sendable {
    var id: String { video.id }
    var video: Video
    /// "720p", or "Audio" for an audio-only download.
    var quality: String
    var isAudioOnly: Bool
    /// The file or `.movpkg`, relative to the home directory: the app container's absolute path changes
    /// between installs and updates, so Apple asks for offline HLS locations to be stored this way.
    var relativePath: String
    var bytes: Int64
    var date: Date
}

/// A download that has started and not finished, kept across launches so a background HLS
/// download that finishes while Koda is not running is still recorded.
nonisolated struct PendingVideoDownload: Codable, Hashable, Sendable {
    var video: Video
    var quality: String
    var isAudioOnly: Bool
    var relativePath: String?
    /// The size the quality sheet showed, for the Live Activity's progress across downloads.
    var estimatedBytes: Int64? = nil
}

/// One quality the viewer can pick for a download.
nonisolated struct VideoDownloadOption: Identifiable, Hashable, Sendable {
    var id: String { label }
    /// "1080p", or "Audio" for audio only.
    var label: String
    var height: Int
    var isAudioOnly: Bool
    var estimatedBytes: Int64?
    var frameRate: Double?

    var title: String { isAudioOnly ? String(localized: "Audio only") : label }
}

/// Video downloads for offline playback.
///
/// Video goes through `AVAssetDownloadURLSession` on the visionOS client's HLS manifest: a VOD playlist
/// with H.264 (MPEG-TS) and VP9 (fMP4) variants and separate AAC renditions, which AVFoundation stores as
/// one `.movpkg` with picture and sound, in a background session that carries on while Koda is suspended.
/// The quality is chosen by picking the exact `AVAssetVariant`. Audio only fetches the AAC file (itag 140)
/// in ranges, as music downloads do.
@MainActor
@Observable
final class VideoDownloadManager {
    static let shared = VideoDownloadManager()

    enum State: Equatable { case preparing, downloading(Double), failed(String) }

    private(set) var items: [DownloadedVideo] = [] { didSet { save() } }
    private(set) var pending: [String: PendingVideoDownload] = [:] { didSet { save() } }
    /// Every change reaches the download Live Activity, which throttles its own updates.
    private(set) var states: [String: State] = [:] { didSet { DownloadActivitySync.refresh(self) } }

    /// Called once the background session has delivered its events (`handleEventsForBackgroundURLSession`).
    @ObservationIgnored var backgroundCompletion: (() -> Void)?

    nonisolated static let sessionIdentifier = "com.koda.video-downloads"

    private struct Prepared {
        var asset: AVURLAsset
        var variants: [String: AVAssetVariant]
        var audioURL: URL?
        var title: String
        var author: String
        var date: Date
    }

    @ObservationIgnored private var session: AVAssetDownloadURLSession!
    @ObservationIgnored private let delegate = VideoDownloadSessionDelegate()
    @ObservationIgnored private var hlsTasks: [String: AVAssetDownloadTask] = [:]
    @ObservationIgnored private var fileTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var prepared: [String: Prepared] = [:]
    /// Packages of cancelled HLS tasks: the daemon can still write to them until the task reports back.
    @ObservationIgnored private var cancelledPaths: [String: String] = [:]
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var loading = true

    private static let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("video-downloads.json")
    }()

    /// Audio-only files. Offline HLS packages live where AVFoundation puts them.
    static let directory: URL = {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()

    private struct Store: Codable { var items: [DownloadedVideo] = []; var pending: [String: PendingVideoDownload] = [:] }

    init() {
        if let raw = try? Data(contentsOf: Self.storeURL), let store = try? JSONDecoder().decode(Store.self, from: raw) {
            items = store.items
            pending = store.pending
        }
        loading = false
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        session = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: delegate, delegateQueue: .main)
        Task { await reattach() }
    }

    // MARK: Queries

    func isDownloaded(_ id: String) -> Bool { items.contains { $0.id == id } }
    func isInProgress(_ id: String) -> Bool {
        switch states[id] { case .preparing, .downloading: true; default: false }
    }

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }

    /// The pending downloads, newest first, for the downloads screen.
    var inProgress: [PendingVideoDownload] { pending.values.sorted { $0.video.title < $1.video.title } }

    func localURL(for id: String) -> URL? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let url = Self.absolute(item.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    nonisolated static func absolute(_ relativePath: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath)
    }

    nonisolated static func relative(_ url: URL) -> String {
        relative(path: url.standardizedFileURL.path, home: URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path)
    }

    /// The download daemon reports locations as `/.nofollow/<home>/Library/…` (and the system may add
    /// or drop `/private`), so the part after the container's own directory is what is kept.
    nonisolated static func relative(path: String, home: String) -> String {
        let container = "/" + (home as NSString).lastPathComponent + "/"
        if let range = path.range(of: container) { return String(path[range.upperBound...]) }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    // MARK: Options

    /// The qualities this video can be downloaded in, highest first, then audio only.
    func options(for video: Video) async throws -> [VideoDownloadOption] {
        if video.isLive { throw InnerTubeError.unplayable(String(localized: "Live streams can't be downloaded.")) }
        let info = try await InnerTube.shared.player(videoId: video.id)
        if info.isLive { throw InnerTubeError.unplayable(String(localized: "Live streams can't be downloaded.")) }
        var options: [VideoDownloadOption] = []
        var variants: [String: AVAssetVariant] = [:]
        var asset: AVURLAsset?
        if let hls = info.hlsURL {
            let a = AVURLAsset(url: hls, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": InnerTube.userAgent(for: hls)]])
            asset = a
            async let sizes = Self.variantSizes(hls)
            let all = (try? await a.load(.variants)) ?? []
            let exact = await sizes
            var best: [String: (variant: AVAssetVariant, score: Double)] = [:]
            for v in all {
                guard let attributes = v.videoAttributes else { continue }
                let size = attributes.presentationSize
                let height = Self.qualityHeight(width: size.width, height: size.height)
                let label = "\(height)p"
                // H.264 first (plays everywhere and is smaller to decode), then the richer audio and frame rate.
                let isH264 = attributes.codecTypes.contains(kCMVideoCodecType_H264)
                let score = (isH264 ? 1e12 : 0) + (attributes.nominalFrameRate ?? 0) * 1e8 + (v.averageBitRate ?? v.peakBitRate ?? 0)
                if score > best[label]?.score ?? -1 { best[label] = (v, score) }
            }
            for (label, entry) in best {
                let rate = entry.variant.averageBitRate ?? entry.variant.peakBitRate
                let size = entry.variant.peakBitRate.flatMap { exact[Int($0)] } ?? rate.map { Int64($0 * info.duration / 8) }
                options.append(VideoDownloadOption(
                    label: label, height: Int(label.dropLast()) ?? 0, isAudioOnly: false,
                    estimatedBytes: size,
                    frameRate: entry.variant.videoAttributes?.nominalFrameRate))
                variants[label] = entry.variant
            }
            options.sort { $0.height > $1.height }
            // Below 360p only when the video has nothing better (old uploads stop at 240p).
            if options.contains(where: { $0.height >= 360 }) {
                options.removeAll { $0.height < 360 }
            }
            variants = variants.filter { label, _ in options.contains { $0.label == label } }
        }
        if info.audioURL != nil {
            options.append(VideoDownloadOption(label: "Audio", height: 0, isAudioOnly: true,
                                               estimatedBytes: info.duration > 0 ? Int64(130_000 * info.duration / 8) : nil))
        }
        guard !options.isEmpty else { throw InnerTubeError.noStream }
        prepared[video.id] = Prepared(asset: asset ?? AVURLAsset(url: info.audioURL!), variants: variants, audioURL: info.audioURL,
                                      title: info.title, author: info.author, date: .now)
        return options
    }

    /// Each variant's size, keyed by its BANDWIDTH: YouTube's playlist URIs carry the video and audio
    /// files' byte counts (`clen=`), which are far closer than BANDWIDTH × duration (BANDWIDTH is a peak).
    @concurrent nonisolated static func variantSizes(_ master: URL) async -> [Int: Int64] {
        var request = URLRequest(url: master)
        request.setValue(InnerTube.userAgent(for: master), forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request), let text = String(data: data, encoding: .utf8) else { return [:] }
        return parseVariantSizes(text)
    }

    nonisolated static func parseVariantSizes(_ text: String) -> [Int: Int64] {
        func attribute(_ name: String, in line: Substring) -> String? {
            guard let range = line.range(of: name + "=") else { return nil }
            let rest = line[range.upperBound...]
            if rest.hasPrefix("\"") { return rest.dropFirst().split(separator: "\"", maxSplits: 1).first.map(String.init) }
            return rest.split(separator: ",", maxSplits: 1).first.map(String.init)
        }
        func clen(_ uri: Substring) -> Int64? {
            guard let range = uri.range(of: "clen%3D") ?? uri.range(of: "clen=") else { return nil }
            return Int64(uri[range.upperBound...].prefix { $0.isNumber })
        }
        let lines = text.split(whereSeparator: \.isNewline)
        var audio: [String: Int64] = [:]
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") && line.contains("TYPE=AUDIO") {
            if let group = attribute("GROUP-ID", in: line), let uri = attribute("URI", in: line), let size = clen(Substring(uri)) {
                audio[group] = size
            }
        }
        var sizes: [Int: Int64] = [:]
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") && i + 1 < lines.count {
            guard let bandwidth = attribute("BANDWIDTH", in: line).flatMap({ Int($0) }), let video = clen(lines[i + 1]) else { continue }
            sizes[bandwidth] = video + (attribute("AUDIO", in: line).flatMap { audio[$0] } ?? 0)
        }
        return sizes
    }

    /// The common name of a rendition, from its longer side, so 1920×800 films and vertical
    /// 1080×1920 videos read as 1080p, as YouTube labels them.
    nonisolated static func qualityHeight(width: Double, height: Double) -> Int {
        let long = max(width, height), short = min(width, height)
        let ladder: [(long: Double, label: Int)] = [(256, 144), (426, 240), (640, 360), (854, 480), (1280, 720), (1920, 1080), (2560, 1440), (3840, 2160), (7680, 4320)]
        // Square or near-square videos have no long side to go by.
        if long < short * 1.2 { return ladder.min { abs(Double($0.label) - short) < abs(Double($1.label) - short) }!.label }
        return ladder.min { abs($0.long - long) < abs($1.long - long) }!.label
    }

    // MARK: Start, cancel, delete

    func start(_ video: Video, option: VideoDownloadOption) {
        guard !isDownloaded(video.id), !isInProgress(video.id) else { return }
        // Stream URLs expire; options more than an hour old are fetched again.
        guard let prep = prepared[video.id], Date.now.timeIntervalSince(prep.date) < 3600 else {
            retry(video, quality: option.label)
            return
        }
        // A video opened from a link has no title until its page loads: take the player's.
        var video = video
        if video.title.isEmpty { video.title = prep.title }
        if video.channel.isEmpty { video.channel = prep.author }
        pending[video.id] = PendingVideoDownload(video: video, quality: option.label, isAudioOnly: option.isAudioOnly,
                                                 estimatedBytes: option.estimatedBytes)
        states[video.id] = .downloading(0)
        if option.isAudioOnly {
            guard let url = prep.audioURL else { fail(video.id, InnerTubeError.noStream); return }
            startFile(video, url: url)
        } else {
            guard let variant = prep.variants[option.label] else { fail(video.id, InnerTubeError.noStream); return }
            let config = AVAssetDownloadConfiguration(asset: prep.asset, title: video.title)
            config.primaryContentConfiguration.variantQualifiers = [AVAssetVariantQualifier(predicate: Self.predicate(for: variant))]
            let task = session.makeAssetDownloadTask(downloadConfiguration: config)
            task.taskDescription = video.id
            hlsTasks[video.id] = task
            task.resume()
            watchProgress()
        }
        prepared[video.id] = nil
    }

    /// Matches one variant by its size and bit rate. A qualifier made from the `AVAssetVariant` itself
    /// reaches the download daemon empty ("qualifiers:(null)") and the task fails with -12640.
    nonisolated static func predicate(for variant: AVAssetVariant) -> NSPredicate {
        var parts: [NSPredicate] = []
        if let size = variant.videoAttributes?.presentationSize {
            parts.append(AVAssetVariantQualifier.predicate(forPresentationWidth: size.width, operatorType: .equalTo))
            parts.append(AVAssetVariantQualifier.predicate(forPresentationHeight: size.height, operatorType: .equalTo))
        }
        if let peak = variant.peakBitRate { parts.append(NSPredicate(format: "peakBitRate == %f", peak)) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// Starts again, in the quality picked before when it is still offered, otherwise the closest one below it.
    func retry(_ video: Video, quality: String? = nil) {
        let wanted = quality ?? pending[video.id]?.quality ?? "720p"
        clear(video.id)
        states[video.id] = .preparing
        Task {
            do {
                let options = try await self.options(for: video)
                guard states[video.id] == .preparing else { return }
                let height = Int(wanted.dropLast()) ?? 0
                let pick = options.first { $0.label == wanted }
                    ?? options.first { !$0.isAudioOnly && $0.height <= height }
                    ?? options.last { !$0.isAudioOnly } ?? options[0]
                states[video.id] = nil
                start(video, option: pick)
            } catch {
                guard states[video.id] == .preparing else { return }
                states[video.id] = .failed(error.localizedDescription)
                pending[video.id] = PendingVideoDownload(video: video, quality: wanted, isAudioOnly: wanted == "Audio")
            }
        }
    }

    func cancel(_ id: String) { clear(id) }

    private func clear(_ id: String) {
        if let task = hlsTasks.removeValue(forKey: id) {
            task.cancel()
            if let path = pending[id]?.relativePath { cancelledPaths[id] = path }
        }
        if let file = fileTasks.removeValue(forKey: id) { file.task.cancel() }
        if let path = pending[id]?.relativePath { try? FileManager.default.removeItem(at: Self.absolute(path)) }
        pending[id] = nil
        states[id] = nil
    }

    func delete(_ id: String) {
        if let item = items.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: Self.absolute(item.relativePath))
        }
        items.removeAll { $0.id == id }
    }

    // MARK: Audio only

    private func startFile(_ video: Video, url: URL) {
        let target = Self.directory.appendingPathComponent("\(video.id).m4a")
        let token = UUID()
        let id = video.id
        let task = Task {
            do {
                let bytes = try await DownloadManager.fetchRanged(url, userAgent: InnerTube.userAgent(for: url), progress: { p in
                    Task { @MainActor in
                        if case .downloading = self.states[id] { self.states[id] = .downloading(p) }
                    }
                }, to: target)
                guard fileTasks[id]?.token == token else { return }
                fileTasks[id] = nil
                finish(id, location: target, bytes: bytes)
            } catch {
                guard fileTasks[id]?.token == token else { return }
                fileTasks[id] = nil
                fail(id, error)
            }
        }
        fileTasks[id] = (token, task)
    }

    // MARK: Session events

    /// After a relaunch: picks up the session's running tasks, and marks downloads whose task is gone
    /// (an audio-only download, or a task the system dropped) as failed so they can be retried.
    private func reattach() async {
        let tasks = await session.allTasks
        for task in tasks {
            guard let id = task.taskDescription, let asset = task as? AVAssetDownloadTask else { continue }
            if pending[id] == nil || isDownloaded(id) { task.cancel(); continue }
            hlsTasks[id] = asset
            if states[id] == nil { states[id] = .downloading(asset.progress.fractionCompleted) }
        }
        for id in pending.keys where hlsTasks[id] == nil && fileTasks[id] == nil && states[id] == nil {
            states[id] = .failed(String(localized: "The download was interrupted."))
        }
        watchProgress()
        removeOrphanedPackages()
    }

    /// Offline packages no download refers to (left by a failure or a cancel while Koda was closed).
    private func removeOrphanedPackages() {
        // A running task that has not said where it writes yet could own any package: leave them all.
        guard hlsTasks.keys.allSatisfy({ pending[$0]?.relativePath != nil }) else { return }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let kept = Set((items.map(\.relativePath) + pending.values.compactMap(\.relativePath)).map { Self.absolute($0).standardizedFileURL.path })
        let folders = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where folder.lastPathComponent.hasPrefix("com.apple.UserManagedAssets") {
            for package in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where package.pathExtension == "movpkg" && !kept.contains(package.standardizedFileURL.path) {
                try? FileManager.default.removeItem(at: package)
            }
        }
    }

    /// A callback from a task this download no longer runs: one cancelled, with a new download of
    /// the same video started before the old task reported back.
    private func isStale(_ id: String, task: Int?) -> Bool {
        guard let task, let current = hlsTasks[id] else { return false }
        return current.taskIdentifier != task
    }

    fileprivate func willDownload(_ id: String, to location: URL, task: Int? = nil) {
        guard !isStale(id, task: task) else {
            // The old task's package: nothing will ever refer to it.
            cancelledPaths[id] = Self.relative(location)
            return
        }
        pending[id]?.relativePath = Self.relative(location)
    }

    fileprivate func progress(_ id: String, _ value: Double, task: Int? = nil) {
        guard !isStale(id, task: task) else { return }
        guard hlsTasks[id] != nil || pending[id] != nil else { return }
        if case .downloading(let old) = states[id], value <= old { return }
        if case .failed = states[id] { return }
        states[id] = .downloading(min(value, 1))
    }

    fileprivate func completed(_ id: String, location: URL?, error: (any Error)?, task: Int? = nil) {
        if let path = cancelledPaths.removeValue(forKey: id) { try? FileManager.default.removeItem(at: Self.absolute(path)) }
        // The cancelled task of an earlier try: the running one owns `pending` and the package.
        if isStale(id, task: task) { return }
        hlsTasks[id] = nil
        let path = location.map(Self.relative) ?? pending[id]?.relativePath
        if let error {
            if (error as? URLError)?.code == .cancelled || (error as NSError).code == NSURLErrorCancelled {
                // A cancel from `clear` has already removed the entry.
                if pending[id] != nil, let path { try? FileManager.default.removeItem(at: Self.absolute(path)) }
                if pending[id] != nil { pending[id] = nil; states[id] = nil }
                return
            }
            if let path { try? FileManager.default.removeItem(at: Self.absolute(path)) }
            // googlevideo refuses a stream now and then (CoreMedia -12938, HTTP 403): usually the
            // visitor token it was resolved under. Resolve it again under a fresh token, once.
            if let p = pending[id], !autoRetried.contains(id), Self.isRefusal(error) {
                autoRetried.insert(id)
                playbackLog.info("download \(id, privacy: .public) refused, retrying with a fresh link")
                Task {
                    _ = await InnerTube.shared.visitorData(forceNew: true)
                    retry(p.video, quality: p.quality)
                }
                return
            }
            autoRetried.remove(id)
            fail(id, error)
            return
        }
        autoRetried.remove(id)
        guard let path else { fail(id, InnerTubeError.empty); return }
        let url = Self.absolute(path)
        finish(id, location: url, bytes: Self.size(of: url))
    }

    /// Downloads already retried once after a refused stream.
    @ObservationIgnored private var autoRetried: Set<String> = []

    nonisolated static func isRefusal(_ error: any Error) -> Bool {
        let ns = error as NSError
        return (ns.domain == "CoreMediaErrorDomain" && [-12938, -12660, -12937, -16845].contains(ns.code))
            || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorBadServerResponse)
    }

    fileprivate func finishedBackgroundEvents() {
        // Update or end the Live Activity before iOS suspends Koda again.
        Task {
            await DownloadActivitySync.flush(self)
            backgroundCompletion?()
            backgroundCompletion = nil
        }
    }

    private func finish(_ id: String, location: URL, bytes: Int64) {
        guard let p = pending[id] else {
            // Cancelled while finishing: nothing asked for this file any more.
            try? FileManager.default.removeItem(at: location)
            return
        }
        items.removeAll { $0.id == id }
        items.insert(DownloadedVideo(video: p.video, quality: p.quality, isAudioOnly: p.isAudioOnly,
                                     relativePath: Self.relative(location), bytes: bytes, date: .now), at: 0)
        pending[id] = nil
        states[id] = nil
    }

    private func fail(_ id: String, _ error: any Error) {
        let ns = error as NSError
        playbackLog.error("download failed \(id, privacy: .public): \(ns.domain, privacy: .public) \(ns.code) \(String(describing: ns.userInfo), privacy: .public)")
        hlsTasks[id] = nil
        pending[id]?.relativePath = nil
        if pending[id] != nil { states[id] = .failed(error.localizedDescription) }
    }

    /// AVAssetDownloadTask's own progress, read twice a second while HLS downloads run.
    private func watchProgress() {
        guard progressTask == nil, !hlsTasks.isEmpty else { return }
        progressTask = Task {
            while !hlsTasks.isEmpty {
                for (id, task) in hlsTasks { progress(id, task.progress.fractionCompleted) }
                try? await Task.sleep(for: .milliseconds(500))
            }
            progressTask = nil
        }
    }

    nonisolated static func size(of url: URL) -> Int64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) } ?? 0
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    private func save() {
        guard !loading else { return }
        let store = Store(items: items, pending: pending)
        if let data = try? JSONEncoder().encode(store) { try? data.write(to: Self.storeURL, options: .atomic) }
    }
}

/// Receives the download session's callbacks on the main queue and hands them to the manager.
final class VideoDownloadSessionDelegate: NSObject, AVAssetDownloadDelegate {
    @MainActor private var manager: VideoDownloadManager? { .shared }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        let id = assetDownloadTask.taskDescription, task = assetDownloadTask.taskIdentifier
        MainActor.assumeIsolated { if let id { manager?.willDownload(id, to: location, task: task) } }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        let id = assetDownloadTask.taskDescription, task = assetDownloadTask.taskIdentifier
        MainActor.assumeIsolated { if let id { manager?.willDownload(id, to: location, task: task) } }
    }

    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                                totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        let id = assetDownloadTask.taskDescription, task = assetDownloadTask.taskIdentifier
        let expected = timeRangeExpectedToLoad.duration.seconds
        let loaded = loadedTimeRanges.reduce(0.0) { $0 + $1.timeRangeValue.duration.seconds }
        guard expected > 0 else { return }
        MainActor.assumeIsolated { if let id { manager?.progress(id, loaded / expected, task: task) } }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard task is AVAssetDownloadTask, let id = task.taskDescription else { return }
        let message = error.map { $0 as NSError }
        let taskId = task.taskIdentifier
        MainActor.assumeIsolated {
            guard let manager else { return }
            let location = manager.pending[id]?.relativePath.map(VideoDownloadManager.absolute)
            manager.completed(id, location: location, error: message, task: taskId)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { manager?.finishedBackgroundEvents() }
    }
}
