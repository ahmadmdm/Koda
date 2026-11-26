import Foundation
@testable import Koda

/// Saved InnerTube and suggestion responses in `Fixtures/`, captured once with curl
/// (signed out, hl=en, gl=US) and scrubbed of tracking ids, visitor data and client IPs,
/// so the parser tests run offline. Files ending in `_ar` were captured with hl=ar, gl=SA.
enum Fixture {
    private final class Token {}

    static func data(_ name: String, extension ext: String = "json") throws -> Data {
        let bundle = Bundle(for: Token.self)
        guard let url = bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name + "." + ext])
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> J {
        let j = J(data: try data(name))
        guard j.exists else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: name + ".json"]) }
        return j
    }
}
