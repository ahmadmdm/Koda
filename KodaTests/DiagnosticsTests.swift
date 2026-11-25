import Foundation
import Testing
@testable import Koda

@Suite struct DiagnosticsTests {
    /// The shape of `MXDiagnosticPayload.jsonRepresentation()`, trimmed.
    static let payload = Data("""
    {"timeStampBegin":"2026-11-23 00:00:00 +0000","timeStampEnd":"2026-11-24 10:15:00 +0000",
     "crashDiagnostics":[{"diagnosticMetaData":{"appVersion":"5.4","exceptionType":1,"signal":11},"callStackTree":{}}],
     "hangDiagnostics":[{"diagnosticMetaData":{"appVersion":"5.4","hangDuration":"3 sec"}},{"diagnosticMetaData":{"appVersion":"5.4"}}],
     "cpuExceptionDiagnostics":[{"diagnosticMetaData":{"appVersion":"5.4"}}]}
    """.utf8)

    @Test func summarizesPayload() throws {
        let report = try #require(Diagnostics.Report.summary(of: Self.payload))
        #expect(report.crashes == 1)
        #expect(report.hangs == 2)
        #expect(report.other == 1)
        #expect(report.appVersion == "5.4")
        #expect(report.date == Date(timeIntervalSince1970: 1_795_515_300))
        #expect(Diagnostics.Report.summary(of: Data("[]".utf8)) == nil)
    }

    @Test func savesEachPayloadOnceAndLists() throws {
        let dir = URL.temporaryDirectory.appending(path: "koda-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let diagnostics = Diagnostics(directory: dir)
        #expect(diagnostics.reports().isEmpty)
        diagnostics.save([Self.payload])
        diagnostics.save([Self.payload])
        let reports = diagnostics.reports()
        #expect(reports.count == 1)
        #expect(try Data(contentsOf: try #require(reports.first).url) == Self.payload)
        diagnostics.delete(reports[0])
        #expect(diagnostics.reports().isEmpty)
    }

    @Test func keepsOnlyTheNewest() throws {
        let dir = URL.temporaryDirectory.appending(path: "koda-diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let diagnostics = Diagnostics(directory: dir)
        let payloads = (0..<(Diagnostics.keep + 5)).map { i in
            Data(#"{"timeStampEnd":"2026-01-01 00:00:\#(String(format: "%02d", i)) +0000","hangDiagnostics":[{}]}"#.utf8)
        }
        diagnostics.save(payloads)
        let reports = diagnostics.reports()
        #expect(reports.count == Diagnostics.keep)
        #expect(reports.first?.date == Diagnostics.Report.parseDate("2026-01-01 00:00:34 +0000"))
    }
}
