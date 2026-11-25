import Foundation
import Network
import os

nonisolated let castLog = Logger(subsystem: "com.koda.ios", category: "cast")

/// A small HTTP server on the iPhone's Wi-Fi address that a Cast receiver fetches media through.
///
/// - `/<token>/m/<url>`: an HLS playlist from googlevideo, fetched with the User-Agent its client needs,
///   rewritten by `HLSPlaylistRewriter` so every URI comes back through here.
/// - `/<token>/s/<url>`: a segment (or init section, key), streamed through as it arrives, with the
///   receiver's `Range` passed on.
/// - `/<token>/f/<id>`: a file on this iPhone (an imported or downloaded song), with `Range` support.
///
/// Every response carries `Access-Control-Allow-Origin: *`: the Default Media Receiver is a web app, and
/// googlevideo's HLS responses have no CORS headers, so it can't load them directly. The random token in
/// every path, and only proxying YouTube's hosts, keep it from being an open proxy on the network.
nonisolated final class CastProxyServer: @unchecked Sendable {
    static let shared = CastProxyServer()

    /// Hosts the proxy fetches from.
    static let allowedHostSuffixes = [".googlevideo.com", ".youtube.com", ".ytimg.com"]

    private let queue = DispatchQueue(label: "com.koda.cast-proxy")
    private let session: URLSession
    private let token: String
    // State below is only touched on `queue`.
    private var listener: NWListener?
    private var port: UInt16?
    private var waiting: [CheckedContinuation<UInt16, Error>] = []
    private var files: [String: URL] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(configuration: URLSessionConfiguration = .default) {
        let config = configuration
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Lifecycle

    /// Starts listening on a random port, if not already, and returns the port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let port { continuation.resume(returning: port); return }
                waiting.append(continuation)
                guard listener == nil else { return }
                do {
                    let parameters = NWParameters.tcp
                    parameters.allowLocalEndpointReuse = true
                    let listener = try NWListener(using: parameters, on: .any)
                    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                    listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                    self.listener = listener
                    listener.start(queue: queue)
                } catch {
                    finishWaiting(.failure(error))
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            port = nil
            for c in connections.values { c.cancel() }
            connections = [:]
            files = [:]
        }
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            port = listener?.port?.rawValue
            if let port { castLog.info("proxy listening on \(port)"); finishWaiting(.success(port)) }
        case .failed(let error):
            castLog.error("proxy failed: \(String(describing: error), privacy: .public)")
            listener?.cancel()
            listener = nil
            port = nil
            finishWaiting(.failure(error))
        case .cancelled:
            port = nil
        default:
            break
        }
    }

    private func finishWaiting(_ result: Result<UInt16, Error>) {
        let pending = waiting
        waiting = []
        for c in pending { c.resume(with: result) }
    }

    // MARK: URLs

    /// The URL a receiver on the same network loads `upstream` (a master or media playlist) from.
    func playlistURL(for upstream: URL, host: String, port: UInt16) -> URL {
        proxyURL(upstream, resource: .playlist, host: host, port: port)
    }

    func proxyURL(_ upstream: URL, resource: HLSPlaylistRewriter.Resource, host: String, port: UInt16) -> URL {
        let encoded = Data(upstream.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        // An extension the receiver's player recognises, after the encoded URL.
        let ext = resource == .playlist ? ".m3u8" : ""
        return URL(string: "http://\(Self.hostLiteral(host)):\(port)/\(token)/\(resource.rawValue)/\(encoded)\(ext)")!
    }

    /// Serves a local file at a new URL until the server stops.
    func fileURL(for file: URL, host: String, port: UInt16) -> URL {
        let id = UUID().uuidString.lowercased() + "." + (file.pathExtension.isEmpty ? "bin" : file.pathExtension.lowercased())
        queue.sync { files[id] = file }
        return URL(string: "http://\(Self.hostLiteral(host)):\(port)/\(token)/f/\(id)")!
    }

    private static func hostLiteral(_ host: String) -> String { host.contains(":") ? "[\(host)]" : host }

    static func decodeUpstream(_ component: String) -> URL? {
        var b64 = component
        if let dot = b64.firstIndex(of: ".") { b64 = String(b64[..<dot]) }
        b64 = b64.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 = b64.padding(toLength: (b64.count + 3) / 4 * 4, withPad: "=", startingAt: 0)
        guard let data = Data(base64Encoded: b64), let s = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: s)
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains { host.hasSuffix($0) }
    }

    /// The iPhone's IPv4 address on Wi-Fi (or wired Ethernet), which a receiver on the network can reach.
    static func lanAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var candidates: [(name: String, address: String)] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            // Link-local addresses aren't reachable from the receiver.
            guard !address.hasPrefix("169.254.") else { continue }
            candidates.append((name, address))
        }
        // en0 is Wi-Fi on an iPhone; then other Ethernet-like interfaces (a USB adapter, the simulator's Mac).
        return candidates.first { $0.name == "en0" }?.address ?? candidates.first { $0.name.hasPrefix("en") }?.address
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed, .cancelled:
                // Handlers run on `queue`, where the table lives.
                self?.connections[id] = nil
                if case .failed = state { connection?.cancel() }
            default: break
            }
        }
        connection.start(queue: queue)
        receiveHeader(connection, buffer: Data())
    }

    private func receiveHeader(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                self.handle(HTTPRequest(head: head), on: connection)
            } else if error != nil || isComplete || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveHeader(connection, buffer: buffer)
            }
        }
    }

    struct HTTPRequest {
        var method = "", path = ""
        var headers: [String: String] = [:]
        init(head: String) {
            let lines = head.components(separatedBy: "\r\n")
            let parts = lines.first?.split(separator: " ") ?? []
            if parts.count >= 2 { method = String(parts[0]).uppercased(); path = String(parts[1]) }
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
    }

    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        if request.method == "OPTIONS" {
            send(connection, status: 204, headers: [:], body: nil)
            return
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            send(connection, status: 405, headers: ["Allow": "GET, HEAD, OPTIONS"], body: nil)
            return
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == token else {
            send(connection, status: 404, headers: [:], body: nil)
            return
        }
        let headOnly = request.method == "HEAD"
        switch parts[1] {
        case "f":
            guard let file = files[parts[2]] else { send(connection, status: 404, headers: [:], body: nil); return }
            serveFile(file, range: request.headers["range"], headOnly: headOnly, on: connection)
        case HLSPlaylistRewriter.Resource.playlist.rawValue, HLSPlaylistRewriter.Resource.segment.rawValue:
            guard let upstream = Self.decodeUpstream(parts[2]), Self.isAllowed(upstream) else {
                send(connection, status: 403, headers: [:], body: nil)
                return
            }
            let host = request.headers["host"] ?? ""
            if parts[1] == HLSPlaylistRewriter.Resource.playlist.rawValue {
                servePlaylist(upstream, requestHost: host, headOnly: headOnly, on: connection)
            } else {
                streamSegment(upstream, range: request.headers["range"], headOnly: headOnly, on: connection)
            }
        default:
            send(connection, status: 404, headers: [:], body: nil)
        }
    }

    // MARK: Responses

    private static let corsHeaders = [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
        "Access-Control-Allow-Headers": "*",
        "Access-Control-Expose-Headers": "Content-Length, Content-Range, Accept-Ranges",
        "Access-Control-Max-Age": "86400",
    ]

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 206: "Partial Content"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 502: "Bad Gateway"
        default: HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        }
    }

    private func headerData(status: Int, headers: [String: String]) -> Data {
        var all = Self.corsHeaders
        all["Connection"] = "close"
        for (k, v) in headers { all[k] = v }
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in all.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8)
    }

    private func send(_ connection: NWConnection, status: Int, headers: [String: String], body: Data?, headOnly: Bool = false) {
        var headers = headers
        headers["Content-Length"] = String(body?.count ?? 0)
        var data = headerData(status: status, headers: headers)
        if let body, !headOnly { data.append(body) }
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func upstreamRequest(_ url: URL, range: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(InnerTube.userAgent(for: url), forHTTPHeaderField: "User-Agent")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }

    private func servePlaylist(_ upstream: URL, requestHost: String, headOnly: Bool, on connection: NWConnection) {
        // Rewritten URIs use the address and port the receiver reached this server on.
        let (host, port) = Self.split(hostHeader: requestHost, fallbackPort: self.port ?? 0)
        session.dataTask(with: upstreamRequest(upstream)) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            guard let data, let http, (200..<300).contains(http.statusCode), let text = String(data: data, encoding: .utf8) else {
                castLog.error("playlist fetch failed: \(http?.statusCode ?? 0) \(String(describing: error), privacy: .public)")
                self.queue.async { self.send(connection, status: 502, headers: [:], body: nil) }
                return
            }
            let base = http.url ?? upstream
            let rewritten = HLSPlaylistRewriter.rewrite(text, base: base) { url, resource in
                self.proxyURL(url, resource: resource, host: host, port: port).absoluteString
            }
            self.queue.async {
                self.send(connection, status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-cache"],
                          body: Data(rewritten.utf8), headOnly: headOnly)
            }
        }.resume()
    }

    static func split(hostHeader: String, fallbackPort: UInt16) -> (String, UInt16) {
        // "192.168.1.5:50123", "[fe80::1]:50123" or just a host.
        if hostHeader.hasPrefix("["), let close = hostHeader.firstIndex(of: "]") {
            let host = String(hostHeader[hostHeader.index(after: hostHeader.startIndex)..<close])
            let rest = hostHeader[hostHeader.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? fallbackPort : fallbackPort)
        }
        let parts = hostHeader.split(separator: ":")
        if parts.count == 2, let port = UInt16(parts[1]) { return (String(parts[0]), port) }
        return (hostHeader.isEmpty ? "127.0.0.1" : hostHeader, fallbackPort)
    }

    private func streamSegment(_ upstream: URL, range: String?, headOnly: Bool, on connection: NWConnection) {
        var request = upstreamRequest(upstream, range: range)
        if headOnly { request.httpMethod = "HEAD" }
        let relay = SegmentRelay(connection: connection, queue: queue, headerData: { [weak self] status, headers in
            self?.headerData(status: status, headers: headers) ?? Data()
        })
        let task = session.dataTask(with: request)
        task.delegate = relay
        relay.task = task
        task.resume()
    }

    private func serveFile(_ file: URL, range: String?, headOnly: Bool, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value else {
            send(connection, status: 404, headers: [:], body: nil)
            return
        }
        var start: Int64 = 0, end: Int64 = size - 1, status = 200
        if let range, let parsed = Self.parseRange(range, size: size) {
            (start, end) = parsed
            status = 206
        } else if range != nil {
            send(connection, status: 416, headers: ["Content-Range": "bytes */\(size)"], body: nil)
            try? handle.close()
            return
        }
        var headers = [
            "Content-Type": Self.contentType(forExtension: file.pathExtension),
            "Content-Length": String(max(0, end - start + 1)),
            "Accept-Ranges": "bytes",
        ]
        if status == 206 { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        connection.send(content: headerData(status: status, headers: headers), completion: .contentProcessed { _ in })
        guard !headOnly, size > 0 else {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        try? handle.seek(toOffset: UInt64(start))
        sendChunks(handle, remaining: end - start + 1, on: connection)
    }

    /// Sends the file a chunk at a time, the next once the last was handed to the network.
    private func sendChunks(_ handle: FileHandle, remaining: Int64, on connection: NWConnection) {
        let chunk = (try? handle.read(upToCount: Int(min(remaining, 256 * 1024)))) ?? Data()
        let left = remaining - Int64(chunk.count)
        let done = chunk.isEmpty || left <= 0
        connection.send(content: chunk, isComplete: done, completion: .contentProcessed { [weak self] error in
            if done || error != nil {
                try? handle.close()
                connection.cancel()
            } else {
                self?.sendChunks(handle, remaining: left, on: connection)
            }
        })
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n` within a file of `size` bytes.
    static func parseRange(_ header: String, size: Int64) -> (Int64, Int64)? {
        guard header.lowercased().hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let ends = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard ends.count == 2 else { return nil }
        if ends[0].isEmpty {
            guard let n = Int64(ends[1]), n > 0 else { return nil }
            return (max(0, size - n), size - 1)
        }
        guard let a = Int64(ends[0]), a < size else { return nil }
        let b = ends[1].isEmpty ? size - 1 : min(Int64(ends[1]) ?? (size - 1), size - 1)
        return b >= a ? (a, b) : nil
    }

    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "m4a", "mp4", "m4b", "aac": ext.lowercased() == "aac" ? "audio/aac" : "audio/mp4"
        case "mp3": "audio/mpeg"
        case "flac": "audio/flac"
        case "wav": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        case "webm", "weba": "audio/webm"
        case "ts": "video/mp2t"
        case "m3u8": "application/vnd.apple.mpegurl"
        default: "application/octet-stream"
        }
    }
}

/// Streams one upstream response to the receiver's connection as it arrives.
nonisolated private final class SegmentRelay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let headerData: (Int, [String: String]) -> Data
    weak var task: URLSessionTask?
    private var sentHeader = false

    init(connection: NWConnection, queue: DispatchQueue, headerData: @escaping (Int, [String: String]) -> Data) {
        self.connection = connection
        self.queue = queue
        self.headerData = headerData
        super.init()
        // The receiver gave up (seeked, changed quality): stop downloading too.
        let previous = connection.stateUpdateHandler
        connection.stateUpdateHandler = { [weak self] state in
            previous?(state)
            switch state {
            case .failed, .cancelled: self?.task?.cancel()
            default: break
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 502
        var headers: [String: String] = ["Content-Type": http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"]
        // URLSession undoes a Content-Encoding, so the upstream length only holds without one.
        if http?.value(forHTTPHeaderField: "Content-Encoding") == nil, response.expectedContentLength >= 0 {
            headers["Content-Length"] = String(response.expectedContentLength)
        }
        if let range = http?.value(forHTTPHeaderField: "Content-Range") { headers["Content-Range"] = range }
        if let ranges = http?.value(forHTTPHeaderField: "Accept-Ranges") { headers["Accept-Ranges"] = ranges }
        let head = headerData(status == 200 || status == 206 ? status : 502, headers)
        queue.async { [self] in
            sentHeader = true
            connection.send(content: head, completion: .contentProcessed { _ in })
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        queue.async { [self] in connection.send(content: data, completion: .contentProcessed { _ in }) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        queue.async { [self] in
            if !sentHeader {
                castLog.error("segment fetch failed: \(String(describing: error), privacy: .public)")
                let head = headerData(502, ["Content-Length": "0"])
                connection.send(content: head, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
                return
            }
            // Close-delimited when the length was unknown; either way the response ends here.
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { [connection] _ in connection.cancel() })
        }
    }
}
