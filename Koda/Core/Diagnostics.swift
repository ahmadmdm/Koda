import CryptoKit
import Foundation
import MetricKit
import SwiftUI

/// Crash and hang reports from MetricKit, kept on the device as JSON in
/// Application Support/Diagnostics. Nothing is uploaded: a report leaves the
/// device only when the user shares it from Settings › Diagnostics.
nonisolated final class Diagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = Diagnostics(directory: URL.applicationSupportDirectory.appending(path: "Diagnostics", directoryHint: .isDirectory))

    /// Older reports beyond this count are removed.
    static let keep = 30

    let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    /// Subscribes to MetricKit and saves any diagnostics delivered before this launch.
    func start() {
        MXMetricManager.shared.add(self)
        save(MXMetricManager.shared.pastDiagnosticPayloads.map { $0.jsonRepresentation() })
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        save(payloads.map { $0.jsonRepresentation() })
    }

    // MARK: Storage

    /// Writes each payload once (MetricKit can deliver the same payload again on a later launch).
    func save(_ payloads: [Data]) {
        guard !payloads.isEmpty else { return }
        lock.withLock {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for data in payloads {
                let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
                let date = Report.summary(of: data)?.date ?? Date()
                let url = directory.appending(path: "\(Self.fileStamp.string(from: date))-\(digest).json")
                guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
                try? data.write(to: url, options: .atomic)
            }
            prune()
        }
    }

    /// Saved reports, newest first.
    func reports() -> [Report] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { Report.summary(of: $0, url: url) } }
            .sorted { $0.date > $1.date }
    }

    func delete(_ report: Report) {
        lock.withLock { try? FileManager.default.removeItem(at: report.url) }
    }

    private func prune() {
        let urls = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in urls.dropFirst(Self.keep) { try? FileManager.default.removeItem(at: url) }
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    // MARK: Report

    struct Report: Identifiable, Hashable, Sendable {
        var id: URL { url }
        var url: URL
        var date: Date
        var crashes: Int
        var hangs: Int
        /// CPU, disk-write and launch diagnostics.
        var other: Int
        var appVersion: String?

        /// Reads the counts and end date from an `MXDiagnosticPayload.jsonRepresentation()`.
        static func summary(of data: Data, url: URL = URL(filePath: "/")) -> Report? {
            let root = J(data: data)
            guard root.dict.isEmpty == false else { return nil }
            let count = { (key: String) in root[key].array.count }
            let date = root["timeStampEnd"].string.flatMap(parseDate) ?? root["timeStampBegin"].string.flatMap(parseDate) ?? .distantPast
            let version = ["crashDiagnostics", "hangDiagnostics", "cpuExceptionDiagnostics", "diskWriteExceptionDiagnostics", "appLaunchDiagnostics"]
                .lazy.compactMap { root[$0][0].path("diagnosticMetaData.appVersion").string }.first
            return Report(url: url, date: date,
                          crashes: count("crashDiagnostics"), hangs: count("hangDiagnostics"),
                          other: count("cpuExceptionDiagnostics") + count("diskWriteExceptionDiagnostics") + count("appLaunchDiagnostics"),
                          appVersion: version)
        }

        /// MetricKit writes dates as "2026-11-24 10:15:00 +0000".
        static func parseDate(_ text: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
                f.dateFormat = format
                if let d = f.date(from: text) { return d }
            }
            return ISO8601DateFormatter().date(from: text)
        }
    }
}

/// Settings › Diagnostics: the saved crash and hang reports, each shareable as its JSON file.
struct DiagnosticsView: View {
    @State private var reports: [Diagnostics.Report] = []

    var body: some View {
        List {
            if reports.isEmpty {
                ContentUnavailableView("No reports", systemImage: "checkmark.seal",
                                       description: Text("When iOS reports a crash or a hang, it appears here, usually a day later."))
            } else {
                Section {
                    ForEach(reports) { report in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.date, format: .dateTime.day().month().year().hour().minute())
                                Text(summary(report)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: report.url) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Export report")
                        }
                    }
                    .onDelete { offsets in
                        for i in offsets { Diagnostics.shared.delete(reports[i]) }
                        reports.remove(atOffsets: offsets)
                    }
                } footer: {
                    Text("Reports stay on this iPhone. Share one to send it with a bug report.")
                }
            }
        }
        .navigationTitle("Diagnostics")
        .task { reports = Diagnostics.shared.reports() }
        .refreshable { reports = Diagnostics.shared.reports() }
    }

    private func summary(_ r: Diagnostics.Report) -> String {
        var parts: [String] = []
        if r.crashes > 0 { parts.append(String(localized: "\(r.crashes) crashes")) }
        if r.hangs > 0 { parts.append(String(localized: "\(r.hangs) hangs")) }
        if r.other > 0 { parts.append(String(localized: "\(r.other) other")) }
        if let v = r.appVersion { parts.append(String(localized: "version \(v)")) }
        return parts.joined(separator: " · ")
    }
}
