import SwiftUI

struct CollectionView: View {
    var browseId: String
    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppState.self) private var app
    @State private var page: CollectionPage?
    @State private var error: String?
    @State private var sort: SongSort = .original

    var body: some View {
        Group {
            if let page {
                content(page)
            } else if let error {
                ErrorView(message: error) { Task { await load() } }
            } else {
                LoadingView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await load() } }
    }

    private func load() async {
        do { page = try await MusicAPI.collection(browseId); error = nil } catch { self.error = error.localizedDescription }
    }

    private func content(_ page: CollectionPage) -> some View {
        let songs = sort.apply(page.songs, library: library)
        let card = MusicCard(kind: page.isAlbum ? .album : .playlist, id: browseId, title: page.title, subtitle: page.subtitle, thumbnail: page.thumbnail)
        return List {
            VStack(spacing: 14) {
                Artwork(url: page.thumbnail.flatMap { URL(string: $0.upscaledThumbnail(800)) }, cornerRadius: 18)
                    .frame(width: 240, height: 240)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                Text(page.title).font(.title2.bold()).multilineTextAlignment(.center)
                Text(page.subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !page.secondSubtitle.isEmpty { Text(page.secondSubtitle).font(.caption).foregroundStyle(.secondary) }
                CollectionActions(songs: songs, card: card)
                if let d = page.description, !d.isEmpty {
                    Text(d).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                SongRow(song: song, index: i + 1, showArtwork: !page.isAlbum) { player.play(songs, startAt: i) }
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sort) { ForEach(SongSort.allCases) { Text($0.title).tag($0) } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort")
            }
        }
    }
}

struct CollectionActions: View {
    var songs: [Song]
    var card: MusicCard?
    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppState.self) private var app

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button { player.play(songs) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                Button { player.play(songs, startAt: Int.random(in: 0..<max(songs.count, 1)), shuffled: true) } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Menu {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(songs) }
                    Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { player.addToQueue(songs) }
                    Button("Add to Playlist…", systemImage: "text.badge.plus") { app.addToPlaylist = songs }
                    Button("Download All", systemImage: "arrow.down.circle") { downloads.download(songs) }
                    if let card {
                        Button(library.isSaved(card) ? "Remove from Library" : "Save to Library",
                               systemImage: library.isSaved(card) ? "minus.circle" : "plus.circle") { library.toggleSaved(card) }
                    }
                } label: { Image(systemName: "ellipsis").frame(width: 30, height: 22) }
                .buttonStyle(.glass)
            }
        }
        .controlSize(.large)
        .disabled(songs.isEmpty)
    }
}

enum SongSort: String, CaseIterable, Identifiable {
    case original, title, artist, plays
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: String(localized: "Default")
        case .title: String(localized: "Title")
        case .artist: String(localized: "Artist")
        case .plays: String(localized: "Play count")
        }
    }
    @MainActor func apply(_ songs: [Song], library: LibraryStore) -> [Song] {
        switch self {
        case .original: return songs
        case .title: return songs.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: return songs.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .plays:
            let counts = Dictionary(library.data.plays.map { ($0.song.id, 1) }, uniquingKeysWith: +)
            return songs.sorted { (counts[$0.id] ?? 0) > (counts[$1.id] ?? 0) }
        }
    }
}

struct ArtistView: View {
    var browseId: String
    @Environment(MusicPlayer.self) private var player
    @Environment(LibraryStore.self) private var library
    @State private var page: ArtistPage?
    @State private var error: String?

    var body: some View {
        Group {
            if let page { content(page) }
            else if let error { ErrorView(message: error) { Task { await load() } } }
            else { LoadingView() }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { if page == nil { await load() } }
    }

    private func load() async {
        do { page = try await MusicAPI.artist(browseId); error = nil } catch { self.error = error.localizedDescription }
    }

    private func content(_ page: ArtistPage) -> some View {
        let card = MusicCard(kind: .artist, id: browseId, title: page.name, subtitle: page.subscribers ?? "", thumbnail: page.thumbnail)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .bottomLeading) {
                    Artwork(url: page.thumbnail.flatMap { URL(string: $0.upscaledThumbnail(1080)) }, cornerRadius: 0, placeholderIcon: "person.fill")
                        .frame(height: 340).clipped()
                        .backgroundExtensionEffect()
                    LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(page.name).font(.system(size: 40, weight: .heavy))
                        if let subs = page.subscribers { Text("\(subs) subscribers").foregroundStyle(.secondary) }
                        HStack {
                            Button { player.play(page.topSongs) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.glassProminent)
                            Button { if let s = page.topSongs.first { player.startRadio(from: s) } } label: {
                                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
                            }.buttonStyle(.glass)
                            Button { library.toggleSaved(card) } label: {
                                Label(library.isSaved(card) ? "Following" : "Follow", systemImage: library.isSaved(card) ? "checkmark" : "plus")
                            }.buttonStyle(.glass)
                        }
                    }
                    .padding()
                }
                if !page.topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top songs").font(.title3.bold()).padding(.horizontal)
                        ForEach(Array(page.topSongs.enumerated()), id: \.element.id) { i, song in
                            SongRow(song: song) { player.play(page.topSongs, startAt: i) }.padding(.horizontal)
                        }
                    }
                }
                ForEach(page.shelves) { ShelfView(shelf: $0) }
                if let d = page.description {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About").font(.title3.bold())
                        Text(d).font(.callout).foregroundStyle(.secondary)
                    }.padding(.horizontal)
                }
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
    }
}
