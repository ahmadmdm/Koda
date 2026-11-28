import CryptoKit
import Foundation
import Observation

/// The user's own Last.fm API account and session. Stored in the Keychain only; the password is
/// never part of it.
nonisolated struct LastFmCredentials: Codable, Sendable {
    var apiKey: String
    var secret: String
    var sessionKey: String?
    var username: String?
}

/// A finished listen waiting to be sent. `timestamp` is when the track started (UNIX seconds, UTC).
nonisolated struct LastFmScrobble: Codable, Hashable, Sendable {
    var artist: String
    var track: String
    var album: String?
    var duration: Int?
    var timestamp: Int
}

nonisolated enum LastFmError: LocalizedError, Sendable {
    case api(code: Int, message: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .api(_, let message): message
        case .badResponse: String(localized: "Last.fm sent an unexpected response.")
        }
    }

    /// Codes Last.fm says to retry later: operation failed, service offline or busy, rate limit.
    var isTemporary: Bool {
        if case .api(let code, _) = self { return [8, 11, 16, 29].contains(code) }
        return true
    }
}

/// Last.fm's web service (https://www.last.fm/api): signed POST requests over HTTPS.
nonisolated enum LastFmAPI {
    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    /// `api_sig`: the parameters sorted by name, each name followed by its value (UTF-8, not
    /// escaped), then the shared secret, hashed with MD5. `format` and `callback` are left out.
    static func signature(_ params: [String: String], secret: String) -> String {
        let text = params.filter { !["format", "callback", "api_sig"].contains($0.key) }
            .sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
            .map { $0.key + $0.value }
            .joined() + secret
        return Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func formBody(_ params: [String: String]) -> Data {
        // RFC 3986 unreserved characters only (ASCII), so `&`, `=`, `+` and spaces in values survive.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = params.sorted { $0.key < $1.key }.map { key, value in
            (key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key) + "=" + (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// Sends a signed call and returns the decoded JSON object, or throws Last.fm's error.
    static func call(_ method: String, _ params: [String: String], apiKey: String, secret: String, sessionKey: String?) async throws -> [String: Any] {
        var all = params
        all["method"] = method
        all["api_key"] = apiKey
        if let sessionKey { all["sk"] = sessionKey }
        all["api_sig"] = signature(all, secret: secret)
        all["format"] = "json"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(all)
        request.timeoutInterval = 20
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LastFmError.badResponse }
        if let code = json["error"] as? Int {
            throw LastFmError.api(code: code, message: json["message"] as? String ?? "Last.fm error \(code)")
        }
        return json
    }

    /// `auth.getMobileSession`: trades a username and password for a session key that does not expire.
    static func mobileSession(username: String, password: String, apiKey: String, secret: String) async throws -> (key: String, name: String) {
        let json = try await call("auth.getMobileSession", ["username": username, "password": password],
                                  apiKey: apiKey, secret: secret, sessionKey: nil)
        guard let session = json["session"] as? [String: Any], let key = session["key"] as? String else { throw LastFmError.badResponse }
        return (key, session["name"] as? String ?? username)
    }

    static func updateNowPlaying(_ s: LastFmScrobble, credentials c: LastFmCredentials) async throws {
        var params = ["artist": s.artist, "track": s.track]
        if let album = s.album, !album.isEmpty { params["album"] = album }
        if let duration = s.duration, duration > 0 { params["duration"] = String(duration) }
        _ = try await call("track.updateNowPlaying", params, apiKey: c.apiKey, secret: c.secret, sessionKey: c.sessionKey)
    }

    /// `track.scrobble` takes up to 50 tracks in one call as `artist[i]`, `track[i]`, ...
    static func scrobble(_ batch: [LastFmScrobble], credentials c: LastFmCredentials) async throws {
        var params: [String: String] = [:]
        for (i, s) in batch.prefix(50).enumerated() {
            params["artist[\(i)]"] = s.artist
            params["track[\(i)]"] = s.track
            params["timestamp[\(i)]"] = String(s.timestamp)
            if let album = s.album, !album.isEmpty { params["album[\(i)]"] = album }
            if let duration = s.duration, duration > 0 { params["duration[\(i)]"] = String(duration) }
        }
        let json = try await call("track.scrobble", params, apiKey: c.apiKey, secret: c.secret, sessionKey: c.sessionKey)
        guard json["scrobbles"] != nil else { throw LastFmError.badResponse }
    }
}

/// Scrobbles what `MusicPlayer` plays to the user's Last.fm account. It samples the player once a
/// second, so the player needs no hooks: "now playing" when a song starts, a scrobble once half
/// the song or 4 minutes has been heard (songs of 30 seconds or less are skipped), as Last.fm's
/// rules ask. Scrobbles wait in a queue on disk until Last.fm accepts them.
@MainActor
@Observable
final class Scrobbler {
    static let shared = Scrobbler()

    private static let keychainService = "com.koda.ios.lastfm"
    private static let keychainAccount = "credentials"

    private(set) var username: String?
    private(set) var apiKey: String = ""
    private(set) var hasSecret = false
    private(set) var pendingCount = 0
    private(set) var lastError: String?
    private(set) var isSigningIn = false
    var enabled = UserDefaults.standard.object(forKey: "lastfmEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "lastfmEnabled"); resetTracking() }
    }

    var isSignedIn: Bool { username != nil }

    @ObservationIgnored private var credentials: LastFmCredentials?
    @ObservationIgnored private var queue: [LastFmScrobble] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private var retryAfter = Date.distantPast
    @ObservationIgnored private var queueWrite: Task<Void, Never>?

    // The listen being measured.
    @ObservationIgnored private var occurrence: String?
    @ObservationIgnored private var startedAt = 0
    @ObservationIgnored private var listened: Double = 0
    @ObservationIgnored private var lastPosition: Double = 0
    @ObservationIgnored private var announced = false
    @ObservationIgnored private var submitted = false

    private static let queueURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lastfm-queue.json")
    }()

    init() {
        if let data = Keychain.read(service: Self.keychainService, account: Self.keychainAccount),
           let stored = try? JSONDecoder().decode(LastFmCredentials.self, from: data) {
            apply(stored)
        }
        if let data = try? Data(contentsOf: Self.queueURL), let saved = try? JSONDecoder().decode([LastFmScrobble].self, from: data) {
            queue = saved
            pendingCount = saved.count
        }
    }

    /// Starts watching the player. Safe to call more than once.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.sample()
                // Without a Last.fm session (most listeners) there is nothing to measure: look again
                // every 10 seconds instead of waking the app every second, in the background too.
                let interval: Duration = self.active ? .seconds(1) : .seconds(10)
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: Account

    func signIn(apiKey: String, secret: String, username: String, password: String) async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !secret.isEmpty, !user.isEmpty, !password.isEmpty else { return }
        isSigningIn = true
        lastError = nil
        defer { isSigningIn = false }
        do {
            let session = try await LastFmAPI.mobileSession(username: user, password: password, apiKey: key, secret: secret)
            if session.name != credentials?.username { clearQueue() }
            store(LastFmCredentials(apiKey: key, secret: secret, sessionKey: session.key, username: session.name))
            resetTracking()
            flush()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Forgets the session and any unsent scrobbles; keeps the API key and secret for next time.
    func signOut() {
        guard var c = credentials else { return }
        c.sessionKey = nil
        c.username = nil
        store(c)
        clearQueue()
        lastError = nil
        resetTracking()
    }

    /// Removes everything Koda keeps for Last.fm from the Keychain.
    func forgetKeys() {
        Keychain.delete(service: Self.keychainService, account: Self.keychainAccount)
        credentials = nil
        apply(nil)
        clearQueue()
        lastError = nil
    }

    /// The saved secret, when the key typed is the saved one (so the secret need not be typed again).
    func storedSecret(forKey key: String) -> String {
        guard let c = credentials, c.apiKey == key.trimmingCharacters(in: .whitespacesAndNewlines) else { return "" }
        return c.secret
    }

    private func store(_ c: LastFmCredentials) {
        if let data = try? JSONEncoder().encode(c) {
            Keychain.write(data, service: Self.keychainService, account: Self.keychainAccount)
        }
        apply(c)
    }

    private func apply(_ c: LastFmCredentials?) {
        credentials = c
        apiKey = c?.apiKey ?? ""
        hasSecret = !(c?.secret.isEmpty ?? true)
        username = c?.sessionKey == nil ? nil : c?.username
    }

    /// Last.fm answered "invalid session key" (the user revoked Koda's access): sign out, keep the queue.
    private func sessionRejected(_ error: Error) {
        guard case LastFmError.api(let code, _) = error, code == 9 || code == 4 || code == 14 else { return }
        guard var c = credentials else { return }
        c.sessionKey = nil
        store(c)
        lastError = String(localized: "Last.fm ended the session. Sign in again.")
    }

    private var active: Bool { enabled && credentials?.sessionKey != nil }

    // MARK: Listening

    private func resetTracking() {
        occurrence = nil
        startedAt = 0
        listened = 0
        lastPosition = 0
        announced = false
        submitted = false
    }

    private func sample() {
        let player = MusicPlayer.shared
        guard active, let song = player.current, !song.isVideo else { resetTracking(); return }
        let artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else { resetTracking(); return }

        let position = player.currentTime
        // A new song, or the same one started over (repeat one, or a seek back to the start).
        if song.id != occurrence || (position < 3 && lastPosition > 10) {
            resetTracking()
            occurrence = song.id
            lastPosition = position
        }
        let duration = player.duration > 0 ? player.duration : Double(song.duration ?? 0)
        let playing = player.isPlaying && !player.isLoading
        if playing {
            if startedAt == 0 { startedAt = Int(Date().timeIntervalSince1970 - position) }
            let delta = position - lastPosition
            // Only time actually heard counts: a seek forward is not listening.
            if delta > 0, delta < 3 { listened += delta }
        }
        lastPosition = position

        let entry = LastFmScrobble(artist: artist, track: title, album: song.album?.isEmpty == false ? song.album : nil,
                                   duration: duration > 0 ? Int(duration.rounded()) : nil, timestamp: startedAt)
        if playing, !announced {
            announced = true
            if let c = credentials {
                Task {
                    do { try await LastFmAPI.updateNowPlaying(entry, credentials: c) }
                    catch { self.sessionRejected(error) }
                }
            }
        }
        if !submitted, duration > 30, startedAt > 0, listened >= min(duration / 2, 240) {
            submitted = true
            enqueue(entry)
        }
        if !queue.isEmpty, Date() >= retryAfter { flush() }
    }

    // MARK: Queue

    private func enqueue(_ s: LastFmScrobble) {
        queue.append(s)
        // Last.fm refuses scrobbles older than two weeks; keep the newest few thousand.
        if queue.count > 3000 { queue.removeFirst(queue.count - 3000) }
        persistQueue()
        retryAfter = .distantPast
        flush()
    }

    private func clearQueue() {
        queue = []
        persistQueue()
    }

    private func persistQueue() {
        pendingCount = queue.count
        let snapshot = queue
        let url = Self.queueURL
        // One write at a time, in order: detached writes racing each other could leave an older
        // queue on disk, so sent scrobbles would be sent again (or new ones lost) after a relaunch.
        let previous = queueWrite
        queueWrite = Task.detached(priority: .utility) {
            await previous?.value
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Sends the queue in batches of 50, oldest first. A failure keeps what is left and retries in
    /// 5 minutes (or with the next scrobble).
    func flush() {
        guard active, !flushing, !queue.isEmpty, let c = credentials else { return }
        flushing = true
        Task {
            defer { flushing = false }
            while active, !queue.isEmpty {
                let batch = Array(queue.prefix(50))
                do {
                    try await LastFmAPI.scrobble(batch, credentials: c)
                    lastError = nil
                    if queue.starts(with: batch) { queue.removeFirst(batch.count) }
                    persistQueue()
                } catch let error as LastFmError where !error.isTemporary {
                    sessionRejected(error)
                    if case .api(let code, _) = error, code == 6 || code == 7 {
                        // Invalid parameters: Last.fm will never take these, so do not block the queue.
                        if queue.starts(with: batch) { queue.removeFirst(batch.count) }
                        persistQueue()
                        continue
                    }
                    lastError = error.localizedDescription
                    retryAfter = Date().addingTimeInterval(300)
                    return
                } catch {
                    if !(error is URLError) { lastError = error.localizedDescription }
                    retryAfter = Date().addingTimeInterval(300)
                    return
                }
            }
        }
    }
}
