import Foundation
@testable import Koda

/// Saved InnerTube and suggestion responses in `Fixtures/`, captured once with curl
/// (signed out, hl=en, gl=US) and scrubbed of tracking ids, visitor data and client IPs,
/// so the parser tests run offline.
enum Fixture {
    private final class Token {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name + ".json"])
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> J {
        let j = J(data: try data(name))
        guard j.exists else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: name + ".json"]) }
        return j
    }
}
