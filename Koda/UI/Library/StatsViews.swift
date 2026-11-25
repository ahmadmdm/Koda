import SwiftUI
import Charts

enum StatsPeriod: String, CaseIterable, Identifiable {
    case week, month, year, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .week: String(localized: "This week")
        case .month: String(localized: "This month")
        case .year: String(localized: "This year")
        case .all: String(localized: "All time")
        }
    }
    var since: Date? {
        let cal = Calendar.current
        switch self {
        case .week: return cal.date(byAdding: .day, value: -7, to: .now)
        case .month: return cal.date(byAdding: .month, value: -1, to: .now)
        case .year: return cal.date(byAdding: .year, value: -1, to: .now)
        case .all: return nil
        }
    }
}

struct StatsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MusicPlayer.self) private var player
    @State private var period: StatsPeriod = .month

    var body: some View {
        let since = period.since
        let songs = library.topSongs(since: since, limit: 25)
        let artists = library.topArtists(since: since, limit: 10)
        let seconds = library.listeningSeconds(since: since)
        let hours = library.playsByHour(since: since)
        List {
            Picker("Period", selection: $period) { ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).listRowBackground(Color.clear)
            Section {
                HStack {
                    stat("\(Int(seconds / 60))", "minutes")
                    stat("\(library.plays(since: since).count)", "plays")
                    stat("\(Set(library.plays(since: since).map(\.song.id)).count)", "songs")
                }
            }
            Section("When you listen") {
                Chart(Array(hours.enumerated()), id: \.offset) { h, count in
                    BarMark(x: .value("Hour", h), y: .value("Plays", count)).foregroundStyle(Color.accentColor.gradient).cornerRadius(3)
                }
                .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
                .frame(height: 150)
            }
            if !artists.isEmpty {
                Section("Top artists") {
                    Chart(artists, id: \.name) { a in
                        BarMark(x: .value("Plays", a.plays), y: .value("Artist", a.name)).foregroundStyle(Color.accentColor.gradient).cornerRadius(4)
                    }
                    .frame(height: CGFloat(artists.count) * 30)
                }
            }
            Section("Top songs") {
                ForEach(Array(songs.enumerated()), id: \.element.song.id) { i, entry in
                    SongRow(song: entry.song, subtitle: String(localized: "\(entry.plays) plays • \(Int(entry.seconds / 60)) min")) {
                        player.play(songs.map(\.song), startAt: i)
                    }
                }
            }
        }
        .readableContentWidth()
        .navigationTitle("Statistics")
        .overlay { if library.data.plays.isEmpty { ContentUnavailableView("No plays yet", systemImage: "chart.bar", description: Text("Statistics come only from plays on this device.")) } }
    }

    private func stat(_ value: String, _ label: LocalizedStringKey) -> some View {
        VStack { Text(value).font(.title.bold()).contentTransition(.numericText()); Text(label).font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity)
    }
}

/// Recap: listening told as a story, ending with a record of your plays.
struct RecapView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MusicPlayer.self) private var player
    @State private var period: StatsPeriod = .month
    @State private var shareImage: Image?

    var body: some View {
        let since = period.since
        let top = library.topSongs(since: since, limit: 5)
        let artists = library.topArtists(since: since, limit: 5)
        let minutes = Int(library.listeningSeconds(since: since) / 60)
        let hours = library.playsByHour(since: since)
        let peak = hours.enumerated().max { $0.element < $1.element }?.offset ?? 20
        ScrollView {
            VStack(spacing: 18) {
                Picker("Period", selection: $period) { ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                if top.isEmpty {
                    ContentUnavailableView("Your recap is waiting", systemImage: "sparkles", description: Text("Play some music and come back."))
                } else {
                    storyCard(colors: [.purple, .indigo]) {
                        Text("You listened for").font(.title3)
                        Text("\(minutes) minutes").font(.system(size: 48, weight: .black))
                        Text(period.title).font(.title3).opacity(0.8)
                    }
                    if let first = top.first {
                        storyCard(colors: [.pink, .orange]) {
                            Text("Your top song").font(.title3)
                            Artwork(url: first.song.artwork, cornerRadius: 18).frame(width: 180, height: 180)
                            Text(first.song.title).font(.title.bold()).multilineTextAlignment(.center)
                            Text("\(first.plays) plays").font(.headline).opacity(0.8)
                            Button { player.play(top.map(\.song)) } label: { Label("Play your top 5", systemImage: "play.fill") }
                                .buttonStyle(.glass)
                        }
                    }
                    storyCard(colors: [.teal, .blue]) {
                        Text("Your regulars").font(.title3)
                        ForEach(Array(artists.enumerated()), id: \.offset) { i, a in
                            HStack { Text("\(i + 1)").font(.title2.bold()).frame(width: 30); Text(a.name).font(.title3.weight(.semibold)); Spacer(); Text("\(a.plays)") }
                        }
                    }
                    storyCard(colors: [.orange, .red]) {
                        Text("Your hour").font(.title3)
                        Text(peakLabel(peak)).font(.system(size: 44, weight: .black))
                        Text("is when you press play the most").opacity(0.8)
                    }
                    let record = recordView(since: since)
                    storyCard(colors: [.black, .gray]) {
                        Text("Your record").font(.title3)
                        record.frame(width: 240, height: 240)
                        Text("One ring for each day, in the colours of your covers.").font(.footnote).opacity(0.8)
                        ShareLink(item: renderShare(top: top), preview: SharePreview("My Koda Recap", image: renderShare(top: top))) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.glass)
                    }
                }
            }
            .padding()
        }
        .readableContentWidth(640)
        .navigationTitle("Recap")
    }

    private func peakLabel(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h
        return (Calendar.current.date(from: c) ?? .now).formatted(.dateTime.hour())
    }

    private func storyCard<C: View>(colors: [Color], @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 12) { content() }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 260)
            .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private func recordView(since: Date?) -> some View {
        let cal = Calendar.current
        let plays = library.plays(since: since)
        let days = Dictionary(grouping: plays) { cal.startOfDay(for: $0.date) }.sorted { $0.key < $1.key }.suffix(40)
        let maxSeconds = days.map { $0.value.reduce(0) { $0 + $1.seconds } }.max() ?? 1
        return ZStack {
            Circle().fill(.black)
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                let seconds = day.value.reduce(0) { $0 + $1.seconds }
                let seed = day.value.first?.song.id.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) } ?? 0
                let hue = Double(abs(seed) % 360) / 360
                Circle()
                    .stroke(Color(hue: hue, saturation: 0.7, brightness: 0.9).opacity(0.25 + 0.75 * seconds / maxSeconds), lineWidth: 2.5)
                    .padding(CGFloat(i) * 2.6 + 6)
            }
            Circle().fill(Color.accentColor).frame(width: 40, height: 40)
            Circle().fill(.black).frame(width: 8, height: 8)
        }
    }

    @MainActor private func renderShare(top: [(song: Song, plays: Int, seconds: Double)]) -> Image {
        let view = VStack(alignment: .leading, spacing: 12) {
            Text("My top songs").font(.largeTitle.bold())
            ForEach(Array(top.enumerated()), id: \.offset) { i, e in
                Text("\(i + 1). \(e.song.title) — \(e.song.artist)").font(.title3)
            }
            Text("Koda Recap • \(period.title)").font(.caption).opacity(0.7)
        }
        .foregroundStyle(.white).padding(40).frame(width: 1080 / 2, height: 1080 / 2, alignment: .leading)
        .background(LinearGradient(colors: [.purple, .indigo], startPoint: .top, endPoint: .bottom))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage.map { Image(uiImage: $0) } ?? Image(systemName: "music.note")
    }
}
