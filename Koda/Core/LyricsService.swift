import Foundation

/// Lyrics from LRCLIB (synced, line-timed) with YouTube Music's plain lyrics as the fallback,
/// mirroring Koda's multi-provider chain.
enum LyricsService {
    @MainActor private static var cache: [String: Lyrics] = [:]

    @MainActor static func lyrics(for song: Song, duration: Double?) async -> Lyrics? {
        let cached = cache[song.id]
        if let cached { return cached }
        var result: Lyrics?
        if let lrc = await lrclib(song: song, duration: duration) { result = lrc }
        else if let plain = await MusicAPI.youtubeLyrics(for: song.id), !plain.isEmpty {
            result = Lyrics(synced: [], plain: plain, source: "YouTube Music")
        }
        if let result { cache[song.id] = result }
        return result
    }

    nonisolated private static func cleanTitle(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[][^\)\]]*(official|video|lyric|audio|visualizer|mv|hd|4k)[^\)\]]*[\)\]]"#, #"\s*\|.*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Off the main actor: JSON and LRC parsing of a whole song's lyrics.
    @concurrent nonisolated private static func lrclib(song: Song, duration: Double?) async -> Lyrics? {
        let artist = song.artist.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? song.artist
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [.init(name: "track_name", value: cleanTitle(song.title)), .init(name: "artist_name", value: artist)]
        if let album = song.album { comps.queryItems?.append(.init(name: "album_name", value: album)) }
        if let d = duration ?? song.duration.map(Double.init), d > 0 { comps.queryItems?.append(.init(name: "duration", value: String(Int(d)))) }
        var json = await fetch(comps.url)
        if json == nil || !(json?["syncedLyrics"].string?.isEmpty == false || json?["plainLyrics"].string?.isEmpty == false) {
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [.init(name: "track_name", value: cleanTitle(song.title)), .init(name: "artist_name", value: artist)]
            if let list = await fetch(search.url) {
                json = list.array.first { $0["syncedLyrics"].string?.isEmpty == false } ?? list.array.first
            }
        }
        guard let json else { return nil }
        if let synced = json["syncedLyrics"].string, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return Lyrics(synced: lines, plain: json["plainLyrics"].string, source: "LRCLIB") }
        }
        if let plain = json["plainLyrics"].string, !plain.isEmpty { return Lyrics(synced: [], plain: plain, source: "LRCLIB") }
        return nil
    }

    nonisolated private static func fetch(_ url: URL?) async -> J? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Koda iOS (https://github.com/Ivorisnoob/Koda)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return J(data: data)
    }

    nonisolated static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let regex = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let body = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                lines.append(LyricLine(id: 0, time: min * 60 + sec, text: body))
            }
        }
        return lines.sorted { $0.time < $1.time }.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}
