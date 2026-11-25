import CryptoKit
import Foundation
import Testing
@testable import Koda

/// Only made-up cookie values here.
@Suite struct AccountSessionHelperTests {
    let cookies = "SID=fake-sid; HSID=fake-hsid; SAPISID=fake/sapisid; __Secure-3PAPISID=fake-3p; PREF=f6=40000000"

    @Test func authorizationIsSapisidHash() throws {
        let origin = "https://music.youtube.com"
        let before = Int(Date().timeIntervalSince1970)
        let header = try #require(AccountSession.authorization(cookies, origin: origin))
        let after = Int(Date().timeIntervalSince1970)
        let match = try #require(header.wholeMatch(of: /SAPISIDHASH (\d+)_([0-9a-f]{40})/))
        let ts = try #require(Int(match.1))
        #expect((before...after).contains(ts))
        let expected = Insecure.SHA1.hash(data: Data("\(ts) fake/sapisid \(origin)".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(String(match.2) == expected)
    }

    @Test func authorizationFallsBackToSecure3PAPISID() throws {
        let header = try #require(AccountSession.authorization("SID=a; __Secure-3PAPISID=fallback", origin: "https://www.youtube.com"))
        let match = try #require(header.wholeMatch(of: /SAPISIDHASH (\d+)_([0-9a-f]{40})/))
        let expected = Insecure.SHA1.hash(data: Data("\(match.1) fallback https://www.youtube.com".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(String(match.2) == expected)
        #expect(AccountSession.authorization("SID=a", origin: "https://www.youtube.com") == nil)
    }

    @Test func readsCookieValues() {
        #expect(AccountSession.value("SID", in: cookies) == "fake-sid")
        #expect(AccountSession.value("PREF", in: cookies) == "f6=40000000")
        #expect(AccountSession.value("MISSING", in: cookies) == nil)
        #expect(AccountSession.value("SID", in: "SID=; HSID=x") == nil)
        #expect(AccountSession.sapisid(cookies) == "fake/sapisid")
    }

    @Test func missingRequired() {
        #expect(AccountSession.missingRequired(cookies).isEmpty)
        #expect(AccountSession.missingRequired("SID=x; __Secure-3PAPISID=y").isEmpty)
        #expect(AccountSession.missingRequired("SID=x") == ["SAPISID"])
        #expect(AccountSession.missingRequired("SAPISID=y") == ["SID"])
        #expect(AccountSession.missingRequired("") == ["SAPISID", "SID"])
        // __Secure-1PSID is not SID.
        #expect(AccountSession.missingRequired("__Secure-1PSID=x; SAPISID=y") == ["SID"])
    }

    @Test func normalizesPastedHeaders() {
        #expect(AccountSession.normalize("  Cookie: SID=a; HSID=b;  \n") == "SID=a; HSID=b")
        #expect(AccountSession.normalize("\"SID=a;\nHSID=b\r\n; SSID=c\"") == "SID=a; HSID=b ; SSID=c")
        #expect(AccountSession.normalize("cookie: SID=a") == "SID=a")
        #expect(AccountSession.normalize("SID=a") == "SID=a")
    }

    @Test func mergesRotatedCookies() {
        let existing = "SID=old; PREF=keep; __Secure-1PSIDTS=ts-old"
        let merged = AccountSession.merge(existing, updates: [
            ("__Secure-1PSIDTS", "ts-new"),   // refreshable, present: replaced in place
            ("__Secure-3PSIDTS", "ts3"),      // refreshable, absent: appended
            ("PREF", "changed"),              // already present: replaced
            ("TRACKER", "nope"),              // neither refreshable nor present: ignored
            ("SID", ""),                      // empty values never clear a cookie
        ])
        #expect(merged == "SID=old; PREF=changed; __Secure-1PSIDTS=ts-new; __Secure-3PSIDTS=ts3")
    }

    @Test func mergeKeepsOrderAndDeduplicates() {
        #expect(AccountSession.merge("A=1; B=2; A=3", updates: []) == "A=3; B=2")
        #expect(AccountSession.merge("", updates: [("SID", "s")]) == "SID=s")
        #expect(AccountSession.merge("FLAG; SID=s", updates: []) == "FLAG=; SID=s")
    }
}
