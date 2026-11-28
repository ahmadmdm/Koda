import Foundation

/// Rewrites YouTube's HLS playlists so a Cast receiver fetches everything through `CastProxyServer`.
///
/// The Default Media Receiver is a web app: it loads HLS with XHR, so every playlist and segment needs
/// `Access-Control-Allow-Origin`, which googlevideo doesn't send. The proxy adds it, and this rewrites
/// each URI (variants, audio renditions, segments, init sections, keys) to point back at the proxy.
///
/// The master playlist is also filtered for the receiver: H.264 + AAC variants up to 1080p only. YouTube
/// lists VP9 variants too, which Chromecasts don't decode inside HLS, and 1440p/2160p ones a Chromecast
/// with Google TV (and older models) can't keep up with.
nonisolated enum HLSPlaylistRewriter {
    /// What a rewritten URI points at: a playlist the proxy rewrites again, or a segment it streams as is.
    enum Resource: String, Sendable { case playlist = "m", segment = "s" }

    /// Builds the proxy URL for an absolute upstream URL.
    typealias ProxyURL = (URL, Resource) -> String

    static func isMasterPlaylist(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    /// Rewrites either kind of playlist; `base` is the playlist's own (final, after redirects) URL.
    static func rewrite(_ text: String, base: URL, maxHeight: Int = 1080, proxy: ProxyURL) -> String {
        isMasterPlaylist(text) ? rewriteMaster(text, base: base, maxHeight: maxHeight, proxy: proxy)
            : rewriteMedia(text, base: base, proxy: proxy)
    }

    // MARK: Master playlist

    struct Variant: Equatable {
        var attributes: [String: String]
        var infoLine: String
        var uri: String
        var height: Int? { attributes["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) } }
        var codecs: [String] { (attributes["CODECS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
        var isH264: Bool { codecs.contains { $0.hasPrefix("avc1") || $0.hasPrefix("avc3") } }
        /// No video codec other than H.264, and AAC (or no) audio.
        var isCastFriendly: Bool {
            isH264 && codecs.allSatisfy { $0.hasPrefix("avc") || $0.hasPrefix("mp4a") }
        }
    }

    /// The variants of a master playlist, in order.
    static func variants(_ text: String) -> [Variant] {
        let lines = text.components(separatedBy: .newlines)
        var result: [Variant] = []
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = attributes(of: line)
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty || lines[j].hasPrefix("#") && !lines[j].hasPrefix("#EXT") { j += 1 }
                if j < lines.count {
                    result.append(Variant(attributes: attrs, infoLine: line, uri: lines[j].trimmingCharacters(in: .whitespaces)))
                    i = j
                }
            }
            i += 1
        }
        return result
    }

    /// The variants the receiver gets: H.264/AAC up to `maxHeight`; failing that, anything up to
    /// `maxHeight`; failing that, everything (a video with only VP9, say, at least gets a try).
    static func castVariants(_ all: [Variant], maxHeight: Int) -> [Variant] {
        let fits = all.filter { ($0.height ?? 0) <= maxHeight }
        let friendly = fits.filter(\.isCastFriendly)
        if !friendly.isEmpty { return friendly }
        if !fits.isEmpty { return fits }
        return all
    }

    static func rewriteMaster(_ text: String, base: URL, maxHeight: Int = 1080, proxy: ProxyURL) -> String {
        let kept = castVariants(variants(text), maxHeight: maxHeight)
        let keptURIs = Set(kept.map(\.uri))
        // Renditions (audio, subtitles) only for the groups the kept variants use.
        var groups: Set<String> = []
        for v in kept { for key in ["AUDIO", "SUBTITLES", "VIDEO"] { if let g = v.attributes[key] { groups.insert(g) } } }

        // Of several audio renditions in one group (a dubbed video), the original is the default:
        // the receiver would otherwise take whichever is marked first.
        let mediaLines = text.components(separatedBy: .newlines).filter { $0.hasPrefix("#EXT-X-MEDIA:") }
        var originalByGroup: [String: String] = [:]
        for line in mediaLines {
            let a = attributes(of: line)
            if a["TYPE"] == "AUDIO", let g = a["GROUP-ID"], let name = a["NAME"], name.lowercased().contains("original") {
                originalByGroup[g] = name
            }
        }

        var out: [String] = []
        let lines = text.components(separatedBy: .newlines)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // The URI on the next line decides whether this variant stays.
                out.append(line)
                continue
            }
            if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = attributes(of: line)
                if let g = a["GROUP-ID"], !groups.isEmpty, !groups.contains(g) { continue }
                var rewritten = rewriteURIAttribute(line, base: base, resource: .playlist, proxy: proxy)
                if a["TYPE"] == "AUDIO", let g = a["GROUP-ID"], let original = originalByGroup[g] {
                    rewritten = setAttribute(rewritten, "DEFAULT", a["NAME"] == original ? "YES" : "NO")
                }
                out.append(rewritten)
                continue
            }
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") {
                let v = Variant(attributes: attributes(of: line), infoLine: line, uri: "")
                guard v.isCastFriendly, (v.height ?? 0) <= maxHeight else { continue }
                out.append(rewriteURIAttribute(line, base: base, resource: .playlist, proxy: proxy))
                continue
            }
            if line.hasPrefix("#") {
                // A session key is fetched as bytes, not a playlist the proxy would parse as text.
                let resource: Resource = line.hasPrefix("#EXT-X-SESSION-KEY:") ? .segment : .playlist
                out.append(line.contains("URI=\"") ? rewriteURIAttribute(line, base: base, resource: resource, proxy: proxy) : line)
                continue
            }
            // A variant's URI: drop it, and its #EXT-X-STREAM-INF, unless it was kept.
            if !keptURIs.contains(line) {
                if out.last?.hasPrefix("#EXT-X-STREAM-INF:") == true { out.removeLast() }
                continue
            }
            out.append(proxyURL(line, base: base, resource: .playlist, proxy: proxy) ?? line)
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Media playlist

    static func rewriteMedia(_ text: String, base: URL, proxy: ProxyURL) -> String {
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                // Keys, init sections (EXT-X-MAP), parts and hints are bytes; a rendition report names
                // another media playlist, which has to be rewritten too.
                let resource: Resource = line.hasPrefix("#EXT-X-RENDITION-REPORT:") ? .playlist : .segment
                out.append(line.contains("URI=\"") ? rewriteURIAttribute(line, base: base, resource: resource, proxy: proxy) : line)
            } else {
                out.append(proxyURL(line, base: base, resource: .segment, proxy: proxy) ?? line)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: Attributes

    /// The attribute list of a tag line (`#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="a,b"`), quotes removed.
    static func attributes(of line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, quoted = false
        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { result[k] = value }
            key = ""; value = ""; inKey = true
        }
        for ch in line[line.index(after: colon)...] {
            if inKey {
                if ch == "=" { inKey = false } else if ch == "," { flush() } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == ",", !quoted {
                flush()
            } else {
                value.append(ch)
            }
        }
        flush()
        return result
    }

    private static func rewriteURIAttribute(_ line: String, base: URL, resource: Resource, proxy: ProxyURL) -> String {
        guard let start = line.range(of: "URI=\""),
              let end = line[start.upperBound...].firstIndex(of: "\"") else { return line }
        let uri = String(line[start.upperBound..<end])
        guard let proxied = proxyURL(uri, base: base, resource: resource, proxy: proxy) else { return line }
        return line.replacingCharacters(in: start.upperBound..<end, with: proxied)
    }

    private static func setAttribute(_ line: String, _ key: String, _ value: String) -> String {
        if let r = line.range(of: "\(key)=") {
            let rest = line[r.upperBound...]
            let end = rest.firstIndex(of: ",") ?? line.endIndex
            return line.replacingCharacters(in: r.upperBound..<end, with: value)
        }
        return line + ",\(key)=\(value)"
    }

    private static func proxyURL(_ uri: String, base: URL, resource: Resource, proxy: ProxyURL) -> String? {
        // Data URIs (inline keys) need no fetch.
        guard !uri.hasPrefix("data:"), let absolute = URL(string: uri, relativeTo: base)?.absoluteURL else { return nil }
        return proxy(absolute, resource)
    }
}
