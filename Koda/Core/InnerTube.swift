import os
import Foundation

nonisolated enum InnerTubeError: LocalizedError {
    case http(Int), unplayable(String), noStream, empty
    var errorDescription: String? {
        switch self {
        case .http(let code): "YouTube answered HTTP \(code)."
        case .unplayable(let reason): reason
        case .noStream: "No playable stream was found."
        case .empty: "Nothing was returned."
        }
    }
}

/// InnerTube on www.youtube.com (WEB), music.youtube.com (WEB_REMIX), and the
/// visionOS `/player` that resolves plain stream URLs - the same split Koda for
/// Android uses (`docs/youtube-data.md`).
nonisolated final class InnerTube: Sendable {
    static let shared = InnerTube()

    static let browserUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let apiKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"
    static let webRemixVersion = "1.20260901.12.00"
    static let webVersion = "2.20260903.01.00"
    static let visionUA = "com.google.visionos.youtube/1.02(RealityDevice14,1; U; CPU visionOS 25_6_0 like Mac OS X; GB)"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Cookies are attached explicitly per account; a shared jar would mix accounts.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    static var defaultLanguage: String { Bundle.main.preferredLocalizations.first == "ar" ? "ar" : "en" }
    var language: String { UserDefaults.standard.string(forKey: "contentLanguage") ?? Self.defaultLanguage }
    var region: String { UserDefaults.standard.string(forKey: "contentRegion") ?? (Locale.current.region?.identifier ?? "US") }

    // MARK: Visitor identity

    private static let visitorKey = "visitorData", visitorAtKey = "visitorDataAt"

    func visitorData(forceNew: Bool = false) async -> String {
        let defaults = UserDefaults.standard
        if !forceNew, let token = defaults.string(forKey: Self.visitorKey),
           Date().timeIntervalSince1970 - defaults.double(forKey: Self.visitorAtKey) < 6 * 3600 {
            return token
        }
        let body: [String: Any] = ["context": ["client": ["clientName": "WEB", "clientVersion": Self.webVersion, "hl": "en", "gl": region]]]
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false")!)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
        if let (data, _) = try? await session.data(for: request),
           let token = J(data: data).path("responseContext.visitorData").string?
               .replacingOccurrences(of: "%3D", with: "=").replacingOccurrences(of: "%3d", with: "="),
           !token.isEmpty {
            defaults.set(token, forKey: Self.visitorKey)
            defaults.set(Date().timeIntervalSince1970, forKey: Self.visitorAtKey)
            return token
        }
        return defaults.string(forKey: Self.visitorKey) ?? ""
    }

    // MARK: Requests

    /// - Parameter signedInOrigin: when set and an account is signed in, the request carries that
    ///   account's cookies and SAPISIDHASH for this origin. Stream resolution never passes it: the
    ///   native player clients answer a signed request with HTTP 400.
    private func post(_ url: String, body: [String: Any], signedInOrigin: String? = nil, headers: [String: String]) async throws -> J {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let account = signedInOrigin.flatMap { AccountSession.shared.authenticate(&request, origin: $0) }
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if let account, let http, let responseURL = http.url {
            AccountSession.shared.mergeRotated(account.id, from: http, url: responseURL)
        }
        guard (200..<300).contains(code) else {
            if let account, code == 401 { AccountSession.shared.markExpired(account.id) }
            throw InnerTubeError.http(code)
        }
        let json = J(data: data)
        if let account { Self.noteSessionState(json, account: account) }
        return json
    }

    /// Every authenticated response says whether YouTube still treats the session as signed in,
    /// and carries the account's stable id.
    private static func noteSessionState(_ json: J, account: YouTubeAccount) {
        let params = json.path("responseContext.serviceTrackingParams").findAll("params").flatMap(\.array)
        if params.contains(where: { $0["key"].string == "logged_in" && $0["value"].string == "0" }) {
            AccountSession.shared.markExpired(account.id)
        }
        if account.datasyncId == nil, let id = json.path("responseContext.mainAppWebResponseContext.datasyncId").string {
            AccountSession.shared.updateProfile(account.id, name: nil, handle: nil, avatar: nil,
                                                datasyncId: id.components(separatedBy: "||").first)
        }
    }

    func music(_ endpoint: String, _ body: [String: Any]) async throws -> J {
        let vd = await visitorData()
        var b = body
        b["context"] = ["client": ["clientName": "WEB_REMIX", "clientVersion": Self.webRemixVersion,
                                   "hl": language, "gl": region, "visitorData": vd]]
        return try await post("https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false", body: b, signedInOrigin: "https://music.youtube.com", headers: [
            "User-Agent": Self.browserUA, "Origin": "https://music.youtube.com", "Referer": "https://music.youtube.com/",
            "X-Goog-Visitor-Id": vd, "X-YouTube-Client-Name": "67", "X-YouTube-Client-Version": Self.webRemixVersion,
        ])
    }

    func web(_ endpoint: String, _ body: [String: Any]) async throws -> J {
        let vd = await visitorData()
        var b = body
        b["context"] = ["client": ["clientName": "WEB", "clientVersion": Self.webVersion,
                                   "hl": language, "gl": region, "visitorData": vd]]
        return try await post("https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false", body: b, signedInOrigin: "https://www.youtube.com", headers: [
            "User-Agent": Self.browserUA, "Origin": "https://www.youtube.com", "Referer": "https://www.youtube.com/",
            "X-Goog-Visitor-Id": vd, "X-YouTube-Client-Name": "1", "X-YouTube-Client-Version": Self.webVersion,
        ])
    }

    // MARK: Player

    private static func nonce(_ n: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<n).map { _ in alphabet.randomElement()! })
    }

    /// One `/player` client identity. A stream URL is bound to the client that resolved it (its `c=`),
    /// and googlevideo can refuse a fetch whose User-Agent belongs to another client.
    nonisolated struct PlayerClient: Sendable {
        var name: String, version: String, id: String, userAgent: String
        var fields: [String: Any & Sendable]
        var sendsNonce = false
    }

    static let visionOS = PlayerClient(name: "VISIONOS", version: "1.02", id: "101", userAgent: visionUA, fields: [
        "clientScreen": "WATCH", "platform": "MOBILE", "deviceMake": "Apple",
        "deviceModel": "RealityDevice14,1", "osName": "visionOS", "osVersion": "25.6.0.23O471",
    ], sendsNonce: true)
    static let iosUA = "com.google.ios.youtube/21.02.3 (iPhone16,2; U; CPU iOS 18_1_0 like Mac OS X)"
    static let iOSClient = PlayerClient(name: "IOS", version: "21.02.3", id: "5", userAgent: iosUA, fields: [
        "deviceMake": "Apple", "deviceModel": "iPhone16,2", "osName": "iPhone", "osVersion": "18.1.0.22B83",
    ])
    static let androidVRUA = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
    static let androidVR = PlayerClient(name: "ANDROID_VR", version: "1.65.10", id: "28", userAgent: androidVRUA, fields: [
        "androidSdkVersion": 32, "deviceMake": "Oculus", "deviceModel": "Quest 3", "osName": "Android", "osVersion": "12L",
    ])

    /// The User-Agent a fetch of `url` must send: the one of the client named in its `c=`.
    static func userAgent(for url: URL) -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "c" }?.value
        switch c {
        case "IOS": return iosUA
        case "ANDROID_VR": return androidVRUA
        default: return visionUA
        }
    }

    /// Streams for a video, as the Android app resolves them: visionOS under the current
    /// visitorData, visionOS again under a fresh one (a refused token reads as "This video is
    /// unavailable"), then IOS and ANDROID_VR as the last resort. Only a reason every client
    /// agrees on (age, region, private) is reported.
    /// `quick` asks visionOS once, for probing alternates where a refusal is the expected answer.
    func player(videoId: String, quick: Bool = false) async throws -> StreamInfo {
        let attempts: [(PlayerClient, Bool)] = quick ? [(Self.visionOS, false)] : [
            (Self.visionOS, false), (Self.visionOS, true), (Self.iOSClient, false), (Self.androidVR, false),
        ]
        var lastError: Error = InnerTubeError.noStream
        for (client, freshToken) in attempts {
            let vd = await visitorData(forceNew: freshToken)
            do {
                let root = try await player(videoId: videoId, client: client, visitorData: vd)
                let status = root.path("playabilityStatus.status").string ?? ""
                guard status == "OK" || status.isEmpty else {
                    lastError = InnerTubeError.unplayable(root.path("playabilityStatus.reason").string ?? status)
                    playbackLog.info("player \(client.name, privacy: .public) \(videoId, privacy: .public): \(status, privacy: .public) hl=\(self.language, privacy: .public) gl=\(self.region, privacy: .public) reason=\(root.path("playabilityStatus.reason").string ?? "", privacy: .public) sub=\(root.path("playabilityStatus.errorScreen.playerErrorMessageRenderer.subreason").text ?? "", privacy: .public)")
                    continue
                }
                let info = Self.parseStream(root)
                guard info.audioURL != nil || info.hlsURL != nil else { lastError = InnerTubeError.noStream; continue }
                return info
            } catch {
                lastError = error
            }
        }
        if case InnerTubeError.unplayable(let reason) = lastError, let hint = await connectionCountryHint() {
            throw InnerTubeError.unplayable(reason + "\n" + hint)
        }
        throw lastError
    }

    /// The country YouTube places this connection in, from the visitorData it minted for it
    /// (field 1 of its location message, e.g. `0a 02 53 41` = "SA").
    func connectionCountry() async -> String? {
        let vd = await visitorData()
        guard let decoded = vd.removingPercentEncoding,
              let data = Data(base64Encoded: decoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                .padding(toLength: (decoded.count + 3) / 4 * 4, withPad: "=", startingAt: 0)) else { return nil }
        let bytes = [UInt8](data)
        for i in stride(from: bytes.count - 4, through: 0, by: -1) where bytes[i] == 0x0A && bytes[i + 1] == 0x02 {
            let code = String(decoding: bytes[(i + 2)...(i + 3)], as: UTF8.self)
            if code.allSatisfy({ $0.isASCII && $0.isUppercase }) { return code }
        }
        return nil
    }

    /// When a video is refused and YouTube sees the connection in another country than the
    /// iPhone's region, a VPN, proxy or DNS that routes YouTube abroad is the usual cause: say so instead of only "unavailable".
    private func connectionCountryHint() async -> String? {
        guard let country = await connectionCountry(), country != region else { return nil }
        let name = Locale.current.localizedString(forRegionCode: country) ?? country
        return String(localized: "YouTube sees your connection as coming from \(name), where this may be blocked. A VPN, proxy or custom DNS (such as NextDNS or Hiddify) can cause this: turn it off for YouTube.")
    }

    private func player(videoId: String, client: PlayerClient, visitorData vd: String) async throws -> J {
        var context: [String: Any] = client.fields
        context["clientName"] = client.name
        context["clientVersion"] = client.version
        context["hl"] = language
        context["gl"] = region
        context["utcOffsetMinutes"] = 0
        context["visitorData"] = vd
        var body: [String: Any] = [
            "videoId": videoId, "context": ["client": context],
            "contentCheckOk": true, "racyCheckOk": true,
        ]
        if client.sendsNonce {
            body["contentPlaybackNonce"] = Self.nonce(16)
            body["t"] = Self.nonce(12)
        }
        return try await post("https://youtubei.googleapis.com/youtubei/v1/player?key=\(Self.apiKey)&prettyPrint=false", body: body, headers: [
            "User-Agent": client.userAgent, "X-Goog-Api-Format-Version": "2", "X-YouTube-Client-Name": client.id,
            "X-YouTube-Client-Version": client.version, "Origin": "https://www.youtube.com", "X-Goog-Visitor-Id": vd,
        ])
    }

    static func parseStream(_ root: J) -> StreamInfo {
        let sd = root["streamingData"]
        let formats = sd["adaptiveFormats"].array + sd["formats"].array
        func audio(_ itag: Int) -> J? { formats.first { $0["itag"].int == itag && $0["url"].exists } }
        let high = audio(140) ?? formats.first { ($0["mimeType"].string ?? "").hasPrefix("audio/mp4") && $0["url"].exists }
        let low = audio(139) ?? high
        let details = root["videoDetails"]
        let captions = root.path("captions.playerCaptionsTracklistRenderer.captionTracks").array.compactMap { t -> CaptionTrack? in
            guard let base = t["baseUrl"].string, let url = URL(string: base + "&fmt=vtt") else { return nil }
            return CaptionTrack(isAutoGenerated: t["kind"].string == "asr", language: t["languageCode"].string ?? "",
                                name: t["name"].text ?? "", url: url)
        }
        return StreamInfo(
            audioURL: high?["url"].string.flatMap(URL.init(string:)),
            lowAudioURL: low?["url"].string.flatMap(URL.init(string:)),
            hlsURL: sd["hlsManifestUrl"].string.flatMap(URL.init(string:)),
            title: details["title"].string ?? "",
            author: details["author"].string ?? "",
            duration: details["lengthSeconds"].double ?? 0,
            loudnessDb: high?["loudnessDb"].double,
            isLive: details["isLiveContent"].bool == true && (details["isLive"].bool ?? false),
            thumbnail: details["thumbnail"].bestThumbnail,
            captions: captions,
            originalAudioLanguage: formats.first { $0.path("audioTrack.audioIsDefault").bool == true }?
                .path("audioTrack.id").string?.components(separatedBy: ".").first
        )
    }
}
