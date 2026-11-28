import AVFoundation
import Observation
import os
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Saves a download outside Koda: to Files (any song or video), or a video to Photos.
///
/// An offline HLS download is a `.movpkg` that neither Files nor Photos can use, so it is first
/// written out as an `.mp4` (passthrough when the package allows it, re-encoded otherwise) into a
/// temporary folder, which goes once the file has been saved or the save was cancelled.
@MainActor
@Observable
final class MediaExporter {
    static let shared = MediaExporter()

    enum Destination { case files, photos }

    struct Job: Equatable {
        var title: String
        var destination: Destination
        /// 0...1 while an `.mp4` is written; nil while preparing or saving.
        var progress: Double?
    }

    private(set) var job: Job?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pickerDelegate: PickerDelegate?
    @ObservationIgnored private weak var progressController: UIViewController?

    nonisolated static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)

    private init() {
        // Copies left by a run that ended mid-save.
        try? FileManager.default.removeItem(at: Self.directory)
    }

    var isBusy: Bool { job != nil }

    // MARK: Starting

    /// Saves a downloaded video (or its audio-only file) to Files or Photos.
    func save(_ download: DownloadedVideo, to destination: Destination) {
        guard let source = VideoDownloadManager.shared.localURL(for: download.id) else {
            AppState.current?.showToast("The download couldn't be found.")
            return
        }
        guard !(destination == .photos && download.isAudioOnly) else { return }
        let title = download.video.title
        start(title: title, destination: destination) { progress in
            let folder = try Self.makeJobFolder()
            if source.pathExtension.lowercased() == "movpkg" {
                let output = folder.appendingPathComponent(Self.fileName(title, fallback: "Video", ext: "mp4"))
                try await Self.exportPackage(source, to: output, progress: progress)
                return output
            }
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            return try await Self.copy(source, to: folder.appendingPathComponent(Self.fileName(title, fallback: "Video", ext: ext)))
        }
    }

    /// Saves a downloaded song, or a music file on this iPhone, to Files.
    func saveToFiles(_ song: Song) {
        guard let source = song.isLocal ? LocalMusicLibrary.fileURL(for: song.id) : DownloadManager.shared.localURL(for: song.id) else {
            AppState.current?.showToast("The download couldn't be found.")
            return
        }
        start(title: song.title, destination: .files) { _ in
            let folder = try Self.makeJobFolder()
            let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
            return try await Self.copy(source, to: folder.appendingPathComponent(Self.fileName(song.title, fallback: "Song", ext: ext)))
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func start(title: String, destination: Destination,
                       make: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> URL) {
        guard job == nil else { AppState.current?.showToast("Another file is being saved."); return }
        job = Job(title: title, destination: destination)
        task = Task {
            // A menu that was just tapped is still going away: present once it has.
            try? await Task.sleep(for: .milliseconds(350))
            presentProgress()
            do {
                let file = try await make { value in
                    Task { @MainActor in
                        let exporter = MediaExporter.shared
                        if exporter.job != nil { exporter.job?.progress = value }
                    }
                }
                try Task.checkCancellation()
                job?.progress = nil
                switch destination {
                case .photos:
                    try await Self.addToPhotos(file)
                    Self.cleanUp(file)
                    finish(saved: "Saved to Photos")
                case .files:
                    await dismissProgress()
                    presentPicker(for: file)
                }
            } catch {
                Self.cleanUp(nil)
                let cancelled = Task.isCancelled || error is CancellationError || (error as NSError).code == NSUserCancelledError
                if cancelled { finish(saved: nil) } else { fail(error.localizedDescription) }
            }
        }
    }

    private func finish(saved message: String.LocalizationValue?) {
        Task {
            await dismissProgress()
            job = nil
            task = nil
            if let message { AppState.current?.showToast(message) }
        }
    }

    private func fail(_ message: String) {
        Task {
            await dismissProgress()
            job = nil
            task = nil
            AppState.current?.showToast("Couldn't save: \(message)")
        }
    }

    // MARK: Presentation (UIKit, so it shows over the watch page and the player as well)

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows) + scenes.flatMap(\.windows)
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }

    private func presentProgress() {
        guard job != nil, progressController == nil, let top = Self.topViewController() else { return }
        let controller = UIHostingController(rootView: ExportProgressView())
        controller.isModalInPresentation = true
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.custom { _ in 170 }]
            sheet.prefersGrabberVisible = false
        }
        progressController = controller
        top.present(controller, animated: true)
    }

    private func dismissProgress() async {
        guard let controller = progressController else { return }
        progressController = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controller.dismiss(animated: true) { done.resume() }
        }
    }

    private func presentPicker(for file: URL) {
        guard let top = Self.topViewController() else { Self.cleanUp(file); finish(saved: nil); return }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        let delegate = PickerDelegate { [weak self] saved in
            Self.cleanUp(file)
            self?.pickerDelegate = nil
            self?.finish(saved: saved ? "Saved to Files" : nil)
        }
        pickerDelegate = delegate
        picker.delegate = delegate
        top.present(picker, animated: true)
    }

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        let done: (Bool) -> Void
        init(done: @escaping (Bool) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done(false) }
    }

    // MARK: Files

    /// A name for the saved file from the title: no characters Files refuses, not too long.
    nonisolated static func fileName(_ title: String, fallback: String, ext: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        var name = title.components(separatedBy: forbidden).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 120 { name = String(name.prefix(120)).trimmingCharacters(in: .whitespaces) }
        if name.isEmpty { name = fallback }
        return name + "." + ext
    }

    nonisolated private static func makeJobFolder() throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `@concurrent`: the job closure runs on its caller's actor, the main one, and a video can be gigabytes.
    @concurrent nonisolated private static func copy(_ source: URL, to target: URL) async throws -> URL {
        try FileManager.default.copyItem(at: source, to: target)
        return target
    }

    /// Removes a saved file's folder, or every export folder.
    nonisolated private static func cleanUp(_ file: URL?) {
        try? FileManager.default.removeItem(at: file?.deletingLastPathComponent() ?? directory)
    }

    /// Writes an offline HLS package out as one `.mp4`, its H.264 and AAC as they are.
    @concurrent nonisolated static func exportPackage(_ source: URL, to output: URL,
                                                       progress: @escaping @Sendable (Double) -> Void) async throws {
        // AVAssetExportSession refuses offline HLS: take the package's segments apart instead.
        do {
            try await HLSPackageRemuxer.remux(source, to: output, progress: progress)
            return
        } catch let error as HLSPackageRemuxer.RemuxError {
            exportLog.error("remux failed: \(String(describing: error), privacy: .public)")
            guard case .unsupported = error else { throw error }
            // A package this can't read: AVFoundation may still manage it.
            do { try await exportWithSession(source, to: output, progress: progress) } catch { throw HLSPackageRemuxer.RemuxError.unsupported }
        }
    }

    @concurrent nonisolated private static func exportWithSession(_ source: URL, to output: URL,
                                                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        var lastError: (any Error)?
        for preset in [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality, AVAssetExportPreset1920x1080] {
            try Task.checkCancellation()
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4),
                  let session = AVAssetExportSession(asset: asset, presetName: preset) else { continue }
            session.shouldOptimizeForNetworkUse = true
            try? FileManager.default.removeItem(at: output)
            // The session reports its states from any thread; only that is read from the monitor.
            let box = SessionBox(session: session)
            let monitor = Task {
                for await state in box.session.states(updateInterval: 0.25) {
                    if case .exporting(let p) = state { progress(p.fractionCompleted) }
                }
            }
            do {
                try await session.export(to: output, as: .mp4)
                monitor.cancel()
                return
            } catch {
                monitor.cancel()
                if Task.isCancelled { throw CancellationError() }
                exportLog.error("export \(preset, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.featureUnsupported)
    }

    nonisolated private struct SessionBox: @unchecked Sendable { let session: AVAssetExportSession }

    // MARK: Photos

    nonisolated private static func addToPhotos(_ file: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Allow A! to add to Photos in Settings › Privacy & Security › Photos."),
            ])
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = file.lastPathComponent
            request.addResource(with: .video, fileURL: file, options: options)
        }
    }
}

nonisolated let exportLog = Logger(subsystem: "com.koda.ios", category: "export")

/// The sheet shown while a download is written out for saving.
struct ExportProgressView: View {
    private var exporter: MediaExporter { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exporter.job?.destination == .photos ? "Saving to Photos…" : "Preparing file…").font(.headline)
                    Text(exporter.job?.title ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Cancel", role: .cancel) { exporter.cancel() }.buttonStyle(.glass)
            }
            if let p = exporter.job?.progress {
                ProgressView(value: p) {
                    EmptyView()
                } currentValueLabel: {
                    Text(p, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
