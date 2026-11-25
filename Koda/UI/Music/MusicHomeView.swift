import SwiftUI

struct ModeSwitcher: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        Picker("Mode", selection: $app.mode) {
            ForEach(AppMode.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 190)
    }
}

struct MusicHomeView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AccountModel.self) private var account
    @AppStorage("homeLayout") private var layout = "mix"
    @State private var shelves: [MusicShelf] = []
    @State private var continuation: String?
    @State private var quickPicks: [Song] = []
    @State private var tasteShelf: MusicShelf?
    @State private var error: String?
    @State private var loading = false
    @State private var spinning = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                Text(greeting).font(.largeTitle.bold()).padding(.horizontal).padding(.top, 4)

                if layout == "spotlight", let hero = (quickPicks.first ?? library.recentSongs.first) {
                    spotlight(hero)
                }

                let dial = library.topSongs(limit: 9).map(\.song)
                if dial.count >= 3 { speedDial(dial) }

                spinCard

                if !quickPicks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Quick picks").font(.title3.bold()).padding(.horizontal)
                        QuickPicksGrid(songs: quickPicks)
                    }
                }

                if let tasteShelf { ShelfView(shelf: tasteShelf) }

                let recent = library.recentSongs.prefix(15)
                if !recent.isEmpty {
                    ShelfView(shelf: MusicShelf(title: String(localized: "Listen again"), items: recent.map {
                        MusicCard(kind: .song, id: $0.id, title: $0.title, subtitle: $0.artist, thumbnail: $0.thumbnail, song: $0)
                    }))
                }

                ForEach(shelves) { ShelfView(shelf: $0) }

                if let error, shelves.isEmpty { ErrorView(message: error) { Task { await load() } } }
                else if loading && shelves.isEmpty { LoadingView() }
                else if continuation != nil {
                    ProgressView().frame(maxWidth: .infinity).padding().task { await loadMore() }
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("Home")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { ModeSwitcher() }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.recap) { Image(systemName: "chart.bar.xaxis") }
            }
        }
        .refreshable { await load() }
        .task(id: account.active?.id) { await load() }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 12 ? String(localized: "Good morning") : h < 18 ? String(localized: "Good afternoon") : String(localized: "Good evening")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let homeTask = MusicAPI.home()
        if let seed = library.recentSongs.first ?? library.data.likedSongs.first?.song {
            quickPicks = (try? await MusicAPI.radio(for: seed.id))?.filter { $0.id != seed.id }.prefix(20).map { $0 } ?? []
        }
        if let artist = library.data.tasteArtists.randomElement(),
           let (cards, _) = try? await MusicAPI.search(artist, filter: .songs) {
            tasteShelf = MusicShelf(title: String(localized: "Because you like \(artist)"), items: Array(cards.prefix(12)))
        }
        do {
            let home = try await homeTask
            shelves = home.shelves
            continuation = home.continuation
            error = nil
            if quickPicks.isEmpty, let firstSong = home.shelves.flatMap(\.items).compactMap(\.song).first {
                quickPicks = (try? await MusicAPI.radio(for: firstSong.id))?.prefix(20).map { $0 } ?? []
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let token = continuation else { return }
        if let more = try? await MusicAPI.home(continuation: token) {
            let existing = Set(shelves.map(\.title))
            shelves += more.shelves.filter { !existing.contains($0.title) }
            continuation = more.continuation
        } else { continuation = nil }
    }

    private func spotlight(_ song: Song) -> some View {
        Button { player.play([song], radio: true) } label: {
            ZStack(alignment: .bottomLeading) {
                Artwork(url: song.largeArtwork ?? song.artwork, cornerRadius: 28).frame(height: 240)
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                VStack(alignment: .leading) {
                    Text("SPOTLIGHT").font(.caption.weight(.bold)).kerning(2)
                    Text(song.title).font(.title.bold()).lineLimit(2)
                    Text(song.artist).font(.headline).opacity(0.8)
                }
                .foregroundStyle(.white).padding(20)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private func speedDial(_ songs: [Song]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Speed dial", systemImage: "bolt.fill").font(.title3.bold()).padding(.horizontal)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                    Button { player.play(songs, startAt: i) } label: {
                        Artwork(url: song.artwork, cornerRadius: 14)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(alignment: .bottomLeading) {
                                Text(song.title).font(.caption2.weight(.semibold)).lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .glassEffect(.regular, in: .capsule)
                                    .padding(6)
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { SongMenuItems(song: song) }
                }
            }
            .padding(.horizontal)
        }
    }

    /// Spin: a wheel of songs for when you cannot decide.
    private var spinCard: some View {
        let pool = Array(Set(library.data.likedSongs.map(\.song) + library.recentSongs.prefix(40) + quickPicks))
        return Button {
            guard let pick = pool.randomElement() else { return }
            withAnimation(.spring(duration: 1.2, bounce: 0.2)) { spinning.toggle() }
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                player.play([pick], radio: true)
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "dial.high.fill").font(.largeTitle)
                    .rotationEffect(.degrees(spinning ? 720 : 0))
                VStack(alignment: .leading) {
                    Text("Spin").font(.headline)
                    Text("Can't decide? Let the wheel pick a song.").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(18)
            .glassEffect(.regular.tint(.accentColor.opacity(0.2)).interactive(), in: .rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .disabled(pool.isEmpty)
        .opacity(pool.isEmpty ? 0.5 : 1)
    }
}
