import CryptoKit
import Foundation
import Security

/// A signed-in YouTube account: the cookie string captured from Google's own sign-in page and
/// what YouTube says about who it belongs to. Ported from Koda for Android (`docs/identity.md`).
nonisolated struct YouTubeAccount: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var cookies: String
    var name: String?
    var handle: String?
    var avatar: String?
    var datasyncId: String?
    var expired = false
}

/// The signed-in accounts and which one is active. Cookies are a credential: they live in the
/// Keychain (this device only, never in backups), never in UserDefaults or the library file.
nonisolated final class AccountSession: @unchecked Sendable {
    static let shared = AccountSession()

    /// Signs the requests made inside `withValue` as this account instead of the active one (to
    /// read each account's subscriptions).
    @TaskLocal static var signingAccount: UUID?

    private let lock = NSLock()
    private var accounts: [YouTubeAccount] = []
    private var activeId: UUID?

    static let didChange = Notification.Name("KodaAccountDidChange")

    private init() {
        if let data = Keychain.read(), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            accounts = stored.accounts
            activeId = stored.activeId
        }
    }

    private struct Stored: Codable { var accounts: [YouTubeAccount]; var activeId: UUID? }

    // MARK: Reading

    var all: [YouTubeAccount] { lock.withLock { accounts } }
    var active: YouTubeAccount? { lock.withLock { accounts.first { $0.id == activeId } } }
    var isSignedIn: Bool { active != nil }

    // MARK: Changing

    /// Saves a session captured at sign-in. The same Google account signed in again replaces its
    /// old row (matched by SID-independent identity once YouTube has told us the datasyncId).
    @discardableResult
    func signIn(cookies: String) -> YouTubeAccount {
        let account = YouTubeAccount(cookies: Self.normalize(cookies))
        lock.withLock {
            accounts.append(account)
            activeId = account.id
        }
        persist(changedIdentity: true)
        return account
    }

    func switchTo(_ id: UUID?) {
        lock.withLock { activeId = id }
        persist(changedIdentity: true)
    }

    func signOut(_ id: UUID) {
        lock.withLock {
            accounts.removeAll { $0.id == id }
            if activeId == id { activeId = accounts.first?.id }
        }
        persist(changedIdentity: true)
    }

    func updateProfile(_ id: UUID, name: String?, handle: String?, avatar: String?, datasyncId: String?) {
        lock.withLock {
            guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
            if let name { accounts[i].name = name }
            if let handle { accounts[i].handle = handle }
            if let avatar { accounts[i].avatar = avatar }
            if let datasyncId {
                accounts[i].datasyncId = datasyncId
                // Signing back into an account already in the list: keep the newer session only.
                accounts.removeAll { $0.id != id && $0.datasyncId == datasyncId }
            }
            accounts[i].expired = false
        }
        persist(changedIdentity: false)
    }

    func markExpired(_ id: UUID) {
        lock.withLock {
            guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
            accounts[i].expired = true
        }
        persist(changedIdentity: false)
    }

    /// Google re-issues the `*PSIDTS` pair every few hours; a session that keeps replaying the
    /// login-time values is eventually answered as signed out. Fold fresh values back in.
    /// A rotation is not a new login, so the account keeps its identity.
    func mergeRotated(_ id: UUID, from response: HTTPURLResponse, url: URL) {
        guard let fields = response.allHeaderFields as? [String: String],
              fields.keys.contains(where: { $0.caseInsensitiveCompare("Set-Cookie") == .orderedSame }) else { return }
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !fresh.isEmpty else { return }
        var changed = false
        lock.withLock {
            guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
            let merged = Self.merge(accounts[i].cookies, updates: fresh.map { ($0.name, $0.value) })
            if merged != accounts[i].cookies { accounts[i].cookies = merged; changed = true }
        }
        if changed { persist(changedIdentity: false) }
    }

    private func persist(changedIdentity: Bool) {
        let snapshot = lock.withLock { Stored(accounts: accounts, activeId: activeId) }
        if let data = try? JSONEncoder().encode(snapshot) { Keychain.write(data) }
        if changedIdentity {
            // The visitor token is the anti-bot identity: never replay one account's under another.
            UserDefaults.standard.removeObject(forKey: "visitorData")
            UserDefaults.standard.removeObject(forKey: "visitorDataAt")
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    // MARK: Cookies and signing

    static let refreshable: Set<String> = [
        "SID", "HSID", "SSID", "APISID", "SAPISID", "LOGIN_INFO", "SIDCC",
        "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS", "__Secure-1PSIDCC", "__Secure-3PSIDCC",
    ]

    static func value(_ name: String, in cookies: String) -> String? {
        for part in cookies.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == name, !pair[1].isEmpty { return String(pair[1]) }
        }
        return nil
    }

    static func sapisid(_ cookies: String) -> String? {
        value("SAPISID", in: cookies) ?? value("__Secure-3PAPISID", in: cookies)
    }

    /// The bar the Android sign-in applies: a SAPISID to sign with and the SID session itself.
    static func missingRequired(_ cookies: String) -> [String] {
        var missing: [String] = []
        if sapisid(cookies) == nil { missing.append("SAPISID") }
        if value("SID", in: cookies) == nil { missing.append("SID") }
        return missing
    }

    static func merge(_ existing: String, updates: [(String, String)]) -> String {
        var order: [String] = []
        var values: [String: String] = [:]
        for part in existing.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            guard let name = pair.first, !name.isEmpty else { continue }
            if values[name] == nil { order.append(name) }
            values[name] = pair.count > 1 ? pair[1] : ""
        }
        for (name, value) in updates where !value.isEmpty && (refreshable.contains(name) || values[name] != nil) {
            if values[name] == nil { order.append(name) }
            values[name] = value
        }
        return order.map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "; ")
    }

    /// Tidies a hand-pasted cookie header (DevTools copy, wrapped lines, quotes).
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        for prefix in ["Cookie:", "cookie:"] where s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
        s = s.replacingOccurrences(of: #"\s*[\r\n]+\s*"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "; ").union(.whitespaces))
    }

    /// `SAPISIDHASH <ts>_<sha1("<ts> <SAPISID> <origin>")>` - per origin.
    static func authorization(_ cookies: String, origin: String) -> String? {
        guard let sapisid = sapisid(cookies) else { return nil }
        let ts = Int(Date().timeIntervalSince1970)
        let digest = Insecure.SHA1.hash(data: Data("\(ts) \(sapisid) \(origin)".utf8))
        return "SAPISIDHASH \(ts)_" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Adds the account's headers to a request for `origin`. Returns the account it signed for,
    /// so a response can be applied to that account and not to whichever is active by then.
    func authenticate(_ request: inout URLRequest, origin: String) -> YouTubeAccount? {
        let chosen = Self.signingAccount.flatMap { id in lock.withLock { accounts.first { $0.id == id } } } ?? active
        guard let account = chosen, let auth = Self.authorization(account.cookies, origin: origin) else { return nil }
        request.setValue(account.cookies, forHTTPHeaderField: "Cookie")
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue(origin, forHTTPHeaderField: "X-Origin")
        return account
    }
}

/// Minimal Keychain storage: generic-password items, this device only, never in backups.
/// With no arguments it reads and writes the YouTube session list, as before.
nonisolated enum Keychain {
    private static func query(service: String, account: String) -> [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ] }

    static func read(service: String = "com.koda.ios.youtube-session", account: String = "accounts") -> Data? {
        var q = query(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    static func write(_ data: Data, service: String = "com.koda.ios.youtube-session", account: String = "accounts") {
        let query = query(service: service, account: account)
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) {
        SecItemDelete(query(service: service, account: account) as CFDictionary)
    }
}
