import Foundation
import Testing
@testable import Koda

/// The HLS rewriting for Cast, on a master and a media playlist saved from YouTube's visionOS
/// `/player` (scrubbed of the client IP and signatures).
@Suite struct HLSPlaylistRewriterTests {
    static let proxyPrefix = "http://192.168.1.20:5000/token/"

    static func proxy(_ url: URL, _ resource: HLSPlaylistRewriter.Resource) -> String {
        proxyPrefix + resource.rawValue + "/" + Data(url.absoluteString.utf8).base64EncodedString()
    }

    static func uris(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func attributeURIs(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).compactMap { line in
            guard let r = line.range(of: "URI=\"") else { return nil }
            return String(line[r.upperBound...].prefix { $0 != "\"" })
        }
    }

    @Test func parsesQuotedAttributes() {
        let a = HLSPlaylistRewriter.attributes(of: #"#EXT-X-STREAM-INF:BANDWIDTH=7417746,CODECS="avc1.64002A,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="234""#)
        #expect(a["BANDWIDTH"] == "7417746")
        #expect(a["CODECS"] == "avc1.64002A,mp4a.40.2")
        #expect(a["RESOLUTION"] == "1920x1080")
        #expect(a["AUDIO"] == "234")
    }

    @Test func filtersMasterToH264UpTo1080p() throws {
        let text = String(decoding: try Fixture.data("hls_master", extension: "m3u8"), as: UTF8.self)
        let base = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/id/x/file/index.m3u8")!
        let all = HLSPlaylistRewriter.variants(text)
        #expect(all.count == 17)
        #expect(all.contains { $0.codecs.contains { $0.hasPrefix("vp09") } })

        let out = HLSPlaylistRewriter.rewrite(text, base: base, proxy: Self.proxy)
        let kept = HLSPlaylistRewriter.variants(out)
        // 144p to 1080p in H.264, the 240p one twice (with HE-AAC and with AAC-LC audio).
        #expect(kept.count == 7)
        #expect(kept.allSatisfy { $0.isCastFriendly })
        #expect(kept.allSatisfy { ($0.height ?? 0) <= 1080 })
        #expect(kept.contains { $0.height == 1080 })
        #expect(!out.contains("vp09"))
        #expect(out.hasPrefix("#EXTM3U\n"))
        #expect(out.contains("#EXT-X-INDEPENDENT-SEGMENTS"))

        // Every variant and rendition goes through the proxy as a playlist, and decodes to the original.
        let variantURIs = Self.uris(out)
        #expect(variantURIs.count == 7)
        let renditions = Self.attributeURIs(out)
        #expect(renditions.count == 2)
        for uri in variantURIs + renditions {
            #expect(uri.hasPrefix(Self.proxyPrefix + "m/"))
            let encoded = String(uri.dropFirst((Self.proxyPrefix + "m/").count))
            let original = try #require(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) })
            #expect(original.hasPrefix("https://manifest.googlevideo.com/api/manifest/hls_playlist/"))
            #expect(text.contains(original))
        }
        // Both audio groups the kept variants use stay.
        #expect(out.contains(#"GROUP-ID="233""#))
        #expect(out.contains(#"GROUP-ID="234""#))
    }

    @Test func rewritesMediaPlaylistSegments() throws {
        let text = String(decoding: try Fixture.data("hls_media", extension: "m3u8"), as: UTF8.self)
        let base = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_playlist/id/x/file/index.m3u8")!
        let out = HLSPlaylistRewriter.rewrite(text, base: base, proxy: Self.proxy)
        let before = Self.uris(text), after = Self.uris(out)
        #expect(before.count == 6)
        #expect(after.count == before.count)
        for (original, rewritten) in zip(before, after) {
            #expect(rewritten.hasPrefix(Self.proxyPrefix + "s/"))
            let encoded = String(rewritten.dropFirst((Self.proxyPrefix + "s/").count))
            #expect(Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf8) } == original)
        }
        #expect(out.contains("#EXT-X-TARGETDURATION:7"))
        #expect(out.components(separatedBy: "#EXTINF:").count == 7)
        #expect(out.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    @Test func resolvesRelativeURIsAndAttributeURIs() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="https://manifest.googlevideo.com/key"
        #EXTINF:4,
        seg/1.ts
        #EXT-X-ENDLIST
        """
        let base = URL(string: "https://rr1---sn-x.googlevideo.com/videoplayback/a/b/index.m3u8")!
        let out = HLSPlaylistRewriter.rewrite(text, base: base) { url, resource in "P:\(resource.rawValue):\(url.absoluteString)" }
        #expect(out.contains(#"#EXT-X-MAP:URI="P:s:https://rr1---sn-x.googlevideo.com/videoplayback/a/b/init.mp4""#))
        #expect(out.contains(#"URI="P:s:https://manifest.googlevideo.com/key""#))
        #expect(out.contains("\nP:s:https://rr1---sn-x.googlevideo.com/videoplayback/a/b/seg/1.ts\n"))
    }

    @Test func prefersTheOriginalAudioOfADub() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:URI="https://manifest.googlevideo.com/a/es",TYPE=AUDIO,GROUP-ID="234",NAME="Spanish - dubbed",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:URI="https://manifest.googlevideo.com/a/en",TYPE=AUDIO,GROUP-ID="234",NAME="English - original",DEFAULT=NO,AUTOSELECT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="avc1.4D401F,mp4a.40.2",RESOLUTION=854x480,AUDIO="234"
        https://manifest.googlevideo.com/v/480
        """
        let out = HLSPlaylistRewriter.rewrite(text, base: URL(string: "https://manifest.googlevideo.com/m")!) { url, _ in url.absoluteString }
        #expect(out.contains(#"NAME="Spanish - dubbed",DEFAULT=NO"#))
        #expect(out.contains(#"NAME="English - original",DEFAULT=YES"#))
    }

    @Test func fallsBackWhenNothingIsH264() {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1,CODECS="vp09.00.40.08,mp4a.40.2",RESOLUTION=1280x720
        https://manifest.googlevideo.com/v/720
        #EXT-X-STREAM-INF:BANDWIDTH=2,CODECS="vp09.00.51.08,mp4a.40.2",RESOLUTION=3840x2160
        https://manifest.googlevideo.com/v/2160
        """
        let out = HLSPlaylistRewriter.rewrite(text, base: URL(string: "https://manifest.googlevideo.com/m")!) { url, _ in url.absoluteString }
        #expect(Self.uris(out) == ["https://manifest.googlevideo.com/v/720"])
    }

    @Test func parsesRanges() {
        #expect(CastProxyServer.parseRange("bytes=0-99", size: 1000)! == (0, 99))
        #expect(CastProxyServer.parseRange("bytes=900-", size: 1000)! == (900, 999))
        #expect(CastProxyServer.parseRange("bytes=-100", size: 1000)! == (900, 999))
        #expect(CastProxyServer.parseRange("bytes=500-5000", size: 1000)! == (500, 999))
        #expect(CastProxyServer.parseRange("bytes=1000-", size: 1000) == nil)
        #expect(CastProxyServer.parseRange("items=0-1", size: 1000) == nil)
    }
}

/// Stands in for googlevideo inside the proxy's URLSession: the saved playlists, and a fake segment.
nonisolated final class FakeGoogleVideo: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var master = Data()
    nonisolated(unsafe) static var media = Data()
    static let segment = Data((0..<200_000).map { UInt8($0 % 251) })
    nonisolated(unsafe) static var userAgents: [String] = []
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix("googlevideo.com") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.userAgents.append(request.value(forHTTPHeaderField: "User-Agent") ?? "") }
        let path = url.path
        let (body, type): (Data, String) = if path.contains("hls_variant") {
            (Self.master, "application/vnd.apple.mpegurl")
        } else if path.contains("hls_playlist") {
            (Self.media, "application/vnd.apple.mpegurl")
        } else {
            (Self.segment, "application/octet-stream")
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": String(body.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // In two pieces, as a network would deliver it.
        let half = body.count / 2
        client?.urlProtocol(self, didLoad: body.prefix(half))
        client?.urlProtocol(self, didLoad: body.dropFirst(half))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The proxy end to end: a real listener on this machine, fetched with URLSession as a receiver would.
@Suite(.serialized) struct CastProxyServerTests {
    static func makeServer() -> CastProxyServer {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGoogleVideo.self]
        return CastProxyServer(configuration: config)
    }

    static func get(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try #require(response as? HTTPURLResponse))
    }

    @Test func proxiesPlaylistsAndSegmentsWithCORS() async throws {
        FakeGoogleVideo.master = try Fixture.data("hls_master", extension: "m3u8")
        FakeGoogleVideo.media = try Fixture.data("hls_media", extension: "m3u8")
        let server = Self.makeServer()
        defer { server.stop() }
        let port = try await server.start()
        let masterUpstream = URL(string: "https://manifest.googlevideo.com/api/manifest/hls_variant/id/6aacfe284f9ba4a4/file/index.m3u8")!
        let masterURL = server.playlistURL(for: masterUpstream, host: "127.0.0.1", port: port)

        // The master: rewritten, filtered, with CORS.
        let (masterData, masterResponse) = try await Self.get(masterURL)
        #expect(masterResponse.statusCode == 200)
        #expect(masterResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(masterResponse.value(forHTTPHeaderField: "Content-Type") == "application/vnd.apple.mpegurl")
        let master = String(decoding: masterData, as: UTF8.self)
        #expect(!master.contains("https://"))
        #expect(!master.contains("vp09"))
        let variants = HLSPlaylistRewriterTests.uris(master)
        #expect(variants.count == 7)
        #expect(variants.allSatisfy { $0.hasPrefix("http://127.0.0.1:\(port)/") })

        // A variant: its segments point back at the proxy too.
        let (mediaData, mediaResponse) = try await Self.get(try #require(URL(string: variants[0])))
        #expect(mediaResponse.statusCode == 200)
        #expect(mediaResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        let segments = HLSPlaylistRewriterTests.uris(String(decoding: mediaData, as: UTF8.self))
        #expect(segments.count == 6)
        #expect(segments.allSatisfy { $0.hasPrefix("http://127.0.0.1:\(port)/") && $0.contains("/s/") })

        // A segment downloads whole, with CORS and its length.
        let (segment, segmentResponse) = try await Self.get(try #require(URL(string: segments[0])))
        #expect(segmentResponse.statusCode == 200)
        #expect(segmentResponse.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(segmentResponse.value(forHTTPHeaderField: "Content-Length") == String(FakeGoogleVideo.segment.count))
        #expect(segment == FakeGoogleVideo.segment)

        // googlevideo got the User-Agent of the client that resolved the URLs.
        #expect(FakeGoogleVideo.userAgents.contains(InnerTube.visionUA))

        // A CORS preflight is answered.
        let (_, preflight) = try await Self.get(masterURL, method: "OPTIONS", headers: ["Origin": "https://www.gstatic.com",
                                                                                     "Access-Control-Request-Method": "GET"])
        #expect(preflight.statusCode == 204)
        #expect(preflight.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
    }

    @Test func refusesOtherPathsAndHosts() async throws {
        let server = Self.makeServer()
        defer { server.stop() }
        let port = try await server.start()
        let good = server.playlistURL(for: URL(string: "https://manifest.googlevideo.com/a")!, host: "127.0.0.1", port: port)
        // A wrong token.
        let wrongToken = URL(string: good.absoluteString.replacingOccurrences(of: "/m/", with: "x/m/"))!
        let (_, refused) = try await Self.get(wrongToken)
        #expect(refused.statusCode == 404)
        // A host that isn't YouTube's.
        let elsewhere = server.proxyURL(URL(string: "https://example.com/a.m3u8")!, resource: .segment, host: "127.0.0.1", port: port)
        let (_, forbidden) = try await Self.get(elsewhere)
        #expect(forbidden.statusCode == 403)
    }

    @Test func servesLocalFilesWithRanges() async throws {
        let server = Self.makeServer()
        defer { server.stop() }
        let port = try await server.start()
        let bytes = Data((0..<300_000).map { UInt8($0 % 241) })
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cast-test-\(UUID().uuidString).m4a")
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let url = server.fileURL(for: file, host: "127.0.0.1", port: port)

        let (whole, response) = try await Self.get(url)
        #expect(response.statusCode == 200)
        #expect(response.value(forHTTPHeaderField: "Content-Type") == "audio/mp4")
        #expect(response.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
        #expect(response.value(forHTTPHeaderField: "Access-Control-Allow-Origin") == "*")
        #expect(whole == bytes)

        let (part, partial) = try await Self.get(url, headers: ["Range": "bytes=1000-1999"])
        #expect(partial.statusCode == 206)
        #expect(partial.value(forHTTPHeaderField: "Content-Range") == "bytes 1000-1999/300000")
        #expect(part == bytes.subdata(in: 1000..<2000))

        let (tail, _) = try await Self.get(url, headers: ["Range": "bytes=299000-"])
        #expect(tail == bytes.suffix(1000))
    }
}
