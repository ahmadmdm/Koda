import Foundation

/// A small read-only view over an untyped InnerTube JSON tree.
/// InnerTube responses are deep and drift often, so parsers read them by
/// key paths and recursive searches rather than strict Codable models.
nonisolated struct J: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw }

    init(data: Data) {
        raw = try? JSONSerialization.jsonObject(with: data)
    }

    subscript(key: String) -> J {
        J((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> J {
        guard let array = raw as? [Any], array.indices.contains(index) else { return J(nil) }
        return J(array[index])
    }

    /// Follow a dotted path such as `"header.title.runs"`.
    func path(_ dotted: String) -> J {
        dotted.split(separator: ".").reduce(self) { node, part in
            if let index = Int(part) { return node[index] }
            return node[String(part)]
        }
    }

    var exists: Bool { raw != nil && !(raw is NSNull) }
    var string: String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }
    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }
    var bool: Bool? { (raw as? NSNumber)?.boolValue }
    var array: [J] { (raw as? [Any])?.map(J.init) ?? [] }
    var dict: [String: J] { ((raw as? [String: Any]) ?? [:]).mapValues(J.init) }
    var keys: [String] { (raw as? [String: Any]).map { Array($0.keys) } ?? [] }

    /// Every value stored under `key` anywhere beneath this node, in document order.
    func findAll(_ key: String) -> [J] {
        var out: [J] = []
        J.collect(raw, key: key, into: &out)
        return out
    }

    func first(_ key: String) -> J {
        J.firstMatch(raw, key: key).map(J.init) ?? J(nil)
    }

    private static func collect(_ node: Any?, key: String, into out: inout [J]) {
        if let dict = node as? [String: Any] {
            for (k, v) in dict {
                if k == key { out.append(J(v)) }
                collect(v, key: key, into: &out)
            }
        } else if let array = node as? [Any] {
            for v in array { collect(v, key: key, into: &out) }
        }
    }

    private static func firstMatch(_ node: Any?, key: String) -> Any? {
        if let dict = node as? [String: Any] {
            if let v = dict[key] { return v }
            for (_, v) in dict { if let found = firstMatch(v, key: key) { return found } }
        } else if let array = node as? [Any] {
            for v in array { if let found = firstMatch(v, key: key) { return found } }
        }
        return nil
    }

    /// Text from `runs`, `simpleText`, or `content` - the three ways InnerTube spells a string.
    var text: String? {
        if let s = raw as? String { return s }
        if let simple = self["simpleText"].string { return simple }
        if let content = self["content"].string { return content }
        let runs = self["runs"].array
        if !runs.isEmpty { return runs.compactMap { $0["text"].string }.joined() }
        return nil
    }

    var runs: [J] { self["runs"].array }

    /// The largest thumbnail URL beneath this node.
    var bestThumbnail: String? {
        let lists = findAll("thumbnails") + findAll("sources")
        var best: (Int, String)?
        for list in lists {
            for t in list.array {
                guard let url = t["url"].string else { continue }
                let w = t["width"].int ?? 0
                if best == nil || w > best!.0 { best = (w, url) }
            }
        }
        guard var url = best?.1 else { return nil }
        if url.hasPrefix("//") { url = "https:" + url }
        return url
    }
}

nonisolated extension String {
    /// Decodes numeric (`&#1593;`, `&#x639;`) and the common named HTML entities.
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        var out = ""
        var rest = self[...]
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            guard let semi = rest[amp...].firstIndex(of: ";"), rest.distance(from: amp, to: semi) <= 10 else {
                out += "&"; rest = rest[rest.index(after: amp)...]; continue
            }
            let entity = String(rest[rest.index(after: amp)..<semi])
            var decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'", "nbsp": " "][entity]
            }
            if let decoded { out += decoded; rest = rest[rest.index(after: semi)...] }
            else { out += "&"; rest = rest[rest.index(after: amp)...] }
        }
        return out + rest
    }

    /// Upscale googleusercontent / ggpht thumbnails, which carry their size in the URL.
    func upscaledThumbnail(_ size: Int = 544) -> String {
        if let range = range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
            return replacingCharacters(in: range, with: "=w\(size)-h\(size)")
        }
        if let range = range(of: #"=s\d+"#, options: .regularExpression) {
            return replacingCharacters(in: range, with: "=s\(size)")
        }
        return self
    }

    /// "4:27" or "1:02:03" to seconds.
    var durationSeconds: Int? {
        let parts = split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == split(separator: ":").count, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

nonisolated extension Int {
    var formattedDuration: String {
        let h = self / 3600, m = (self % 3600) / 60, s = self % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

nonisolated extension Double {
    var formattedDuration: String {
        guard isFinite, self >= 0 else { return "0:00" }
        return Int(self).formattedDuration
    }
}
