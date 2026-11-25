import Foundation

/// The part of the day a time-of-day mix is for.
nonisolated enum Daypart: String, CaseIterable, Sendable {
    case morning, afternoon, evening, night

    init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        case 17..<22: self = .evening
        default: self = .night
        }
    }

    func contains(hour: Int) -> Bool { Daypart(hour: hour) == self }

    var title: String {
        switch self {
        case .morning: String(localized: "Morning Mix")
        case .afternoon: String(localized: "Afternoon Mix")
        case .evening: String(localized: "Evening Mix")
        case .night: String(localized: "Late Night Mix")
        }
    }

    var symbol: String {
        switch self {
        case .morning: "sunrise.fill"
        case .afternoon: "sun.max.fill"
        case .evening: "sunset.fill"
        case .night: "moon.stars.fill"
        }
    }
}

/// A one-tap mix on the CarPlay Home screen ("For the Drive").
nonisolated struct DriveMix: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// Liked and most played songs with a radio from the top favourite.
        case drive
        /// What the listener plays at this time of day, extended with a radio.
        case daypart(Daypart)
        /// Radios from the last few songs, without anything already played or liked.
        case fresh
        /// One artist: their songs from the library and search, then their radio.
        case artist(String)
        /// Downloads and songs on this iPhone, for driving without a signal.
        case offline
    }

    var kind: Kind

    var title: String {
        switch kind {
        case .drive: String(localized: "Drive Mix")
        case .daypart(let part): part.title
        case .fresh: String(localized: "Fresh Finds")
        case .artist(let name): String(localized: "\(name) Mix")
        case .offline: String(localized: "Offline Mix")
        }
    }

    var subtitle: String {
        switch kind {
        case .drive: String(localized: "Favourites and radio")
        case .daypart: String(localized: "Made for right now")
        case .fresh: String(localized: "New to you")
        case .artist: String(localized: "Artist mix")
        case .offline: String(localized: "No signal needed")
        }
    }

    var symbol: String {
        switch kind {
        case .drive: "car.fill"
        case .daypart(let part): part.symbol
        case .fresh: "sparkles"
        case .artist: "music.mic"
        case .offline: "arrow.down.circle.fill"
        }
    }

    /// A hue in 0...1 for the mix's tile.
    var hue: Double {
        switch kind {
        case .drive: 0.95
        case .daypart(.morning): 0.11
        case .daypart(.afternoon): 0.55
        case .daypart(.evening): 0.04
        case .daypart(.night): 0.68
        case .fresh: 0.42
        case .artist(let name): Double(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }) / 65535
        case .offline: 0.33
        }
    }
}

/// What a mix is made from, read from the library once so the planning below is plain and testable.
nonisolated struct MixInputs: Sendable {
    var liked: [Song] = []
    var top: [Song] = []
    var plays: [PlayRecord] = []
    var offline: [Song] = []
    var tasteArtists: [String] = []
    var topArtists: [String] = []

    var recent: [Song] {
        var seen = Set<String>()
        return plays.reversed().map(\.song).filter { seen.insert($0.id).inserted }
    }
}

/// The songs a mix starts from and the songs whose radio extends it.
nonisolated struct MixPlan: Sendable {
    var base: [Song]
    var radioSeeds: [String]
    var exclude: Set<String> = []
    var shuffleAll = false
    /// An artist mix looks this artist up in search for more songs.
    var searchArtist: String?
}

nonisolated enum MixPlanner {
    static let maximumArtistMixes = 3

    /// The mixes worth showing for this library, most personal first.
    static func mixes(for inputs: MixInputs, hour: Int, limit: Int) -> [DriveMix] {
        var out: [DriveMix] = []
        let hasFavourites = !inputs.liked.isEmpty || !inputs.top.isEmpty
        if hasFavourites { out.append(DriveMix(kind: .drive)) }
        if hasFavourites || !inputs.plays.isEmpty { out.append(DriveMix(kind: .daypart(Daypart(hour: hour)))) }
        if !inputs.plays.isEmpty { out.append(DriveMix(kind: .fresh)) }
        var seen = Set<String>()
        let artists = (inputs.tasteArtists + inputs.topArtists)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        out += artists.prefix(maximumArtistMixes).map { DriveMix(kind: .artist($0)) }
        if !inputs.offline.isEmpty { out.append(DriveMix(kind: .offline)) }
        return Array(out.prefix(max(0, limit)))
    }

    static func plan(_ mix: DriveMix, inputs: MixInputs, hour: Int) -> MixPlan {
        switch mix.kind {
        case .drive:
            let base = unique(Array(inputs.top.prefix(15)) + Array(inputs.liked.shuffled().prefix(15)))
            let seed = inputs.top.first ?? inputs.liked.first
            return MixPlan(base: base, radioSeeds: seed.map { [$0.id] } ?? [], shuffleAll: true)
        case .daypart(let part):
            var counts: [String: (song: Song, plays: Int)] = [:]
            let cal = Calendar.current
            for p in inputs.plays where part.contains(hour: cal.component(.hour, from: p.date)) {
                counts[p.song.id] = (p.song, (counts[p.song.id]?.plays ?? 0) + 1)
            }
            var base = counts.values.sorted { $0.plays > $1.plays }.prefix(20).map(\.song)
            if base.isEmpty { base = Array(inputs.top.prefix(10)) + Array(inputs.liked.prefix(10)) }
            base = unique(base)
            return MixPlan(base: base, radioSeeds: base.prefix(2).map(\.id), shuffleAll: true)
        case .fresh:
            let known = Set(inputs.plays.map(\.song.id)).union(inputs.liked.map(\.id))
            return MixPlan(base: [], radioSeeds: inputs.recent.prefix(3).map(\.id), exclude: known, shuffleAll: true)
        case .artist(let name):
            let mine = unique(inputs.recent.filter { matches($0, artist: name) } + inputs.liked.filter { matches($0, artist: name) })
            return MixPlan(base: Array(mine.prefix(10)), radioSeeds: mine.first.map { [$0.id] } ?? [], searchArtist: name)
        case .offline:
            return MixPlan(base: inputs.offline.shuffled(), radioSeeds: [])
        }
    }

    /// The final queue: the base songs and the radios woven together, without repeats or
    /// excluded songs, starting with a song the listener knows when there is one.
    static func assemble(_ plan: MixPlan, radios: [[Song]], limit: Int = 80) -> [Song] {
        let radio = interleave(radios).filter { !plan.exclude.contains($0.id) }
        let songs: [Song]
        if plan.shuffleAll {
            let first = plan.base.first
            var rest = Array(plan.base.dropFirst()) + radio
            rest.shuffle()
            songs = (first.map { [$0] } ?? []) + rest
        } else {
            songs = interleave([plan.base, radio])
        }
        return Array(unique(songs).prefix(limit))
    }

    static func matches(_ song: Song, artist: String) -> Bool {
        song.artist.localizedCaseInsensitiveContains(artist)
    }

    static func unique(_ songs: [Song]) -> [Song] {
        var seen = Set<String>()
        return songs.filter { seen.insert($0.id).inserted }
    }

    /// a1 b1 c1 a2 b2 c2 …
    static func interleave(_ lists: [[Song]]) -> [Song] {
        var out: [Song] = []
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest { for list in lists where i < list.count { out.append(list[i]) } }
        return out
    }
}

/// Builds a mix's queue: reads the library, then fetches the radios and the artist search in
/// parallel, each bounded by a timeout so a weak signal never leaves the driver waiting.
@MainActor
enum MixBuilder {
    static func inputs() -> MixInputs {
        let library = LibraryStore.shared
        let downloads = library.data.downloads.map(\.song)
        return MixInputs(liked: library.data.likedSongs.map(\.song),
                         top: library.topSongs(limit: 40).map(\.song),
                         plays: Array(library.data.plays.suffix(3000)),
                         offline: MixPlanner.unique(downloads + LocalMusicLibrary.shared.songs),
                         tasteArtists: library.data.tasteArtists,
                         topArtists: library.topArtists(limit: 6).map(\.name))
    }

    static func build(_ mix: DriveMix, hour: Int = Calendar.current.component(.hour, from: .now)) async -> [Song] {
        let inputs = inputs()
        var plan = MixPlanner.plan(mix, inputs: inputs, hour: hour)
        if let name = plan.searchArtist {
            let found = await withTimeout(seconds: 6) {
                (try? await MusicAPI.search(name, filter: .songs).0)?.compactMap(\.song) ?? []
            } ?? []
            let byArtist = found.filter { MixPlanner.matches($0, artist: name) }
            plan.base = MixPlanner.unique(plan.base + Array((byArtist.isEmpty ? found : byArtist).prefix(10)))
            if plan.radioSeeds.isEmpty, let first = plan.base.first { plan.radioSeeds = [first.id] }
        }
        let seeds = plan.radioSeeds.filter { !$0.hasPrefix(LocalMusicLibrary.idPrefix) }
        let radios = await withTaskGroup(of: (Int, [Song]).self) { group in
            for (i, seed) in seeds.enumerated() {
                group.addTask {
                    (i, await withTimeout(seconds: 8) { (try? await MusicAPI.radio(for: seed)) ?? [] } ?? [])
                }
            }
            var out = Array(repeating: [Song](), count: seeds.count)
            for await (i, songs) in group { out[i] = songs }
            return out
        }
        return MixPlanner.assemble(plan, radios: radios)
    }

    /// The operation's result, or nil when it takes longer than `seconds`.
    nonisolated static func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
