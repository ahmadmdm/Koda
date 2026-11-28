import SwiftUI
import UniformTypeIdentifiers

struct MusicLibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AccountModel.self) private var account
    @Environment(DownloadManager.self) private var downloads
    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var showImporter = false

    var body: some View {
        List {
            Section {
                row(.liked, "Liked songs", "heart.fill", .pink, library.data.likedSongs.count.formatted())
                row(.downloads, "Downloads", "arrow.down.circle.fill", .green, library.data.downloads.count.formatted())
                row(.history, "History", "clock.fill", .orange, nil)
                row(.stats, "Statistics", "chart.bar.fill", .blue, nil)
                row(.recap, "Recap", "sparkles.rectangle.stack.fill", .purple, nil)
                row(.savedCollections, "Albums & playlists", "square.stack.3d.up.fill", .teal, library.data.savedCollections.count.formatted())
                row(.followedArtists, "Artists", "music.microphone", .indigo, library.data.followedArtists.count.formatted())
            }
            LocalMusicSection()
            if account.isSignedIn { AccountMusicLibrarySection() }
            Section {
                ForEach(library.data.playlists) { p in
                    NavigationLink(value: Route.localPlaylist(p.id)) {
                        HStack(spacing: 12) {
                            GeneratedCover(name: p.name, hue: p.coverHue, songs: p.songs, cornerRadius: 8).frame(width: 52, height: 52)
                            VStack(alignment: .leading) {
                                Text(p.name)
                                Text("\(p.songs.count) songs").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { idx in idx.map { library.data.playlists[$0].id }.forEach(library.deletePlaylist) }
                .onMove { library.data.playlists.move(fromOffsets: $0, toOffset: $1) }
            } header: {
                HStack {
                    Text("Playlists")
                    Spacer()
                    Menu {
                        Button("New Playlist", systemImage: "plus") { showNewPlaylist = true }
                        Button("Import CSV…", systemImage: "square.and.arrow.down") { showImporter = true }
                    } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    .accessibilityLabel("Add Playlist")
                }
            }
        }
        .readableContentWidth()
        .navigationTitle("Library")
        .toolbar { ToolbarItem(placement: .principal) { ModeSwitcher() }; ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Name", text: $newName)
            Button("Create") { library.createPlaylist(newName.isEmpty ? String(localized: "My Playlist") : newName); newName = "" }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case .success(let url) = result { importCSV(url) }
        }
    }

    private func row(_ route: Route, _ title: LocalizedStringKey, _ icon: String, _ color: Color, _ detail: String?) -> some View {
        NavigationLink(value: route) {
            HStack {
                Label { Text(title) } icon: {
                    Image(systemName: icon).foregroundStyle(.white).frame(width: 30, height: 30)
                        .background(color.gradient, in: RoundedRectangle(cornerRadius: 8))
                }
                Spacer()
                // No "0": in Arabic its digit (٠) reads as a stray dot.
                if let detail, detail != 0.formatted() { Text(detail).foregroundStyle(.secondary).monospacedDigit() }
            }
        }
    }

    private func importCSV(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let songs = PlaylistCSV.parse(text)
        if !songs.isEmpty { library.createPlaylist(url.deletingPathExtension().lastPathComponent, songs: songs) }
    }
}

nonisolated enum PlaylistCSV {
    static func export(_ playlist: LocalPlaylist) throws -> URL {
        var csv = "videoId,title,artist,album,duration\n"
        func q(_ s: String?) -> String { "\"" + (s ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        for s in playlist.songs { csv += [s.id, q(s.title), q(s.artist), q(s.album), s.duration.map(String.init) ?? ""].joined(separator: ",") + "\n" }
        // A "/" or ":" in the name would point the file at a folder that doesn't exist.
        let safeName = playlist.name.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeName.isEmpty ? "Playlist" : safeName).csv")
        try csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func parse(_ text: String) -> [Song] {
        text.components(separatedBy: .newlines).dropFirst().compactMap { line in
            let f = fields(line)
            guard f.count >= 3, !f[0].isEmpty else { return nil }
            return Song(id: f[0], title: f[1], artist: f[2], album: f.count > 3 && !f[3].isEmpty ? f[3] : nil,
                        duration: f.count > 4 ? Int(f[4]) : nil, thumbnail: "https://i.ytimg.com/vi/\(f[0])/hqdefault.jpg")
        }
    }

    private static func fields(_ line: String) -> [String] {
        var out: [String] = [], cur = "", quoted = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            if c == "\"" {
                if quoted, chars.first == "\"" { cur.append("\""); chars.removeFirst() } else { quoted.toggle() }
            } else if c == ",", !quoted { out.append(cur); cur = "" }
            else { cur.append(c) }
        }
        out.append(cur)
        return out
    }
}

/// A playlist's CSV, written only when it is actually shared rather than on every redraw of the menu.
nonisolated struct PlaylistCSVFile: Transferable {
    var playlist: LocalPlaylist
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { SentTransferredFile(try PlaylistCSV.export($0.playlist)) }
    }
}

struct LocalPlaylistView: View {
    var playlistId: UUID
    @Environment(LibraryStore.self) private var library
    @Environment(MusicPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var name = ""
    @State private var sort: SongSort = .original

    var body: some View {
        if let playlist = library.playlist(playlistId) {
            let songs = sort.apply(playlist.songs, library: library)
            List {
                VStack(spacing: 14) {
                    GeneratedCover(name: playlist.name, hue: playlist.coverHue, songs: playlist.songs, cornerRadius: 18).frame(width: 220, height: 220)
                    Text(playlist.name).font(.title2.bold())
                    Text("\(playlist.songs.count) songs • \(Int(playlist.songs.compactMap(\.duration).reduce(0, +) / 60)) min")
                        .font(.subheadline).foregroundStyle(.secondary)
                    CollectionActions(songs: songs)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
                if playlist.songs.isEmpty {
                    ContentUnavailableView("Empty playlist", systemImage: "music.note.list", description: Text("Add songs from any song's menu."))
                }
                // By position: an imported CSV or a saved queue can hold the same song twice.
                ForEach(Array(songs.enumerated()), id: \.offset) { i, song in
                    SongRow(song: song) { player.play(songs, startAt: i) }
                }
                .onDelete { idx in
                    var p = playlist
                    if sort == .original {
                        // Offsets match the stored order: remove exactly the rows swiped, not every copy.
                        p.songs.remove(atOffsets: idx)
                    } else {
                        let ids = Set(idx.map { songs[$0].id })
                        p.songs.removeAll { ids.contains($0.id) }
                    }
                    library.updatePlaylist(p)
                }
                .onMove { from, to in
                    guard sort == .original else { return }
                    var p = playlist; p.songs.move(fromOffsets: from, toOffset: to); library.updatePlaylist(p)
                }
            }
            .listStyle(.plain)
            .readableContentWidth()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sort) { ForEach(SongSort.allCases) { Text($0.title).tag($0) } }
                        Button("Rename", systemImage: "pencil") { name = playlist.name; renaming = true }
                        Button("New Cover Colour", systemImage: "paintpalette") { var p = playlist; p.coverHue = .random(in: 0...1); library.updatePlaylist(p) }
                        ShareLink(item: PlaylistCSVFile(playlist: playlist), preview: SharePreview(playlist.name)) {
                            Label("Export CSV", systemImage: "square.and.arrow.up")
                        }
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) { library.deletePlaylist(playlist.id); dismiss() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More")
                }
                ToolbarItem(placement: .topBarTrailing) { EditButton() }
            }
            .alert("Rename Playlist", isPresented: $renaming) {
                TextField("Name", text: $name)
                Button("Save") { var p = playlist; p.name = name; library.updatePlaylist(p) }
                Button("Cancel", role: .cancel) {}
            }
        } else {
            ContentUnavailableView("Playlist deleted", systemImage: "trash")
        }
    }
}

struct LikedSongsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MusicPlayer.self) private var player
    @State private var sort: SongSort = .original
    var body: some View {
        let songs = sort.apply(library.data.likedSongs.map(\.song), library: library)
        List {
            CollectionActions(songs: songs).listRowBackground(Color.clear).listRowSeparator(.hidden)
            ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in SongRow(song: s) { player.play(songs, startAt: i) } }
                .onDelete { idx in idx.map { songs[$0] }.forEach(library.toggleLike) }
        }
        .listStyle(.plain)
        .overlay { if songs.isEmpty { ContentUnavailableView("No liked songs", systemImage: "heart", description: Text("Tap the heart on any song.")) } }
        .readableContentWidth()
        .navigationTitle("Liked songs")
        .toolbar {
            Menu { Picker("Sort", selection: $sort) { ForEach(SongSort.allCases) { Text($0.title).tag($0) } } } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort")
        }
    }
}

struct DownloadsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(MusicPlayer.self) private var player

    var body: some View {
        let songs = library.data.downloads.map(\.song)
        let videos = VideoDownloadManager.shared
        List {
            if !videos.items.isEmpty || !videos.pending.isEmpty {
                Section {
                    NavigationLink(value: Route.videoDownloads) {
                        HStack {
                            Label("Videos", systemImage: "play.rectangle.fill")
                            Spacer()
                            Text("\(videos.items.count) • \(ByteCountFormatter.string(fromByteCount: videos.totalBytes, countStyle: .file))")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !downloads.pending.isEmpty {
                Section("In progress") {
                    ForEach(downloads.pending) { song in
                        HStack {
                            Artwork(url: song.artwork, cornerRadius: 6).frame(width: 44, height: 44)
                            VStack(alignment: .leading) {
                                Text(song.title).lineLimit(1)
                                switch downloads.active[song.id] {
                                case .downloading(let p): ProgressView(value: p)
                                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red).lineLimit(1)
                                default: Text("Queued").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if case .failed = downloads.active[song.id] {
                                Button { downloads.retry(song) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass)
                                    .accessibilityLabel("Retry Download")
                            }
                            Button { downloads.cancel(song.id) } label: { Image(systemName: "xmark") }.buttonStyle(.glass)
                                .accessibilityLabel("Cancel Download")
                        }
                    }
                }
            }
            Section {
                CollectionActions(songs: songs).listRowBackground(Color.clear)
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, s in
                    SongRow(song: s) { player.play(songs, startAt: i) }
                        .swipeActions(edge: .leading) {
                            Button("Save to Files…", systemImage: "folder") { MediaExporter.shared.saveToFiles(s) }.tint(.blue)
                        }
                }
                .onDelete { idx in idx.map { songs[$0].id }.forEach(downloads.delete) }
            } footer: {
                Text("\(songs.count) songs • \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)) on this iPhone")
            }
        }
        .listStyle(.plain)
        .overlay { if songs.isEmpty && downloads.pending.isEmpty && videos.items.isEmpty && videos.pending.isEmpty { ContentUnavailableView("No downloads", systemImage: "arrow.down.circle", description: Text("Downloaded songs play without a connection.")) } }
        .readableContentWidth()
        .navigationTitle("Downloads")
    }
}

struct HistoryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MusicPlayer.self) private var player
    @State private var confirmClear = false

    var body: some View {
        let grouped = Dictionary(grouping: library.data.plays.reversed().prefix(1000)) { Calendar.current.startOfDay(for: $0.date) }
        let days = grouped.keys.sorted(by: >)
        List {
            ForEach(days, id: \.self) { day in
                Section(day.formatted(date: .complete, time: .omitted)) {
                    ForEach(Array(grouped[day]!.enumerated()), id: \.offset) { _, play in
                        SongRow(song: play.song, subtitle: "\(play.song.artist) • \(play.date.formatted(date: .omitted, time: .shortened)) • " + String(localized: "\(Int(play.seconds / 60)) min listened")) {
                            player.play([play.song], radio: true)
                        }
                    }
                }
            }
        }
        .overlay { if days.isEmpty { ContentUnavailableView("No history", systemImage: "clock") } }
        .readableContentWidth()
        .navigationTitle("History")
        .toolbar { Button("Clear", role: .destructive) { confirmClear = true }.disabled(days.isEmpty) }
        .confirmationDialog("Clear listening history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { library.data.plays.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your statistics and recap are built from this history. This can't be undone.")
        }
    }
}

struct SavedCollectionsView: View {
    @Environment(LibraryStore.self) private var library
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(library.data.savedCollections) { CardLink(card: $0, width: 160) }
            }
            .padding()
        }
        .overlay { if library.data.savedCollections.isEmpty { ContentUnavailableView("Nothing saved", systemImage: "square.stack", description: Text("Save albums and playlists from their menu.")) } }
        .navigationTitle("Albums & playlists")
    }
}

struct FollowedArtistsView: View {
    @Environment(LibraryStore.self) private var library
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 16)], spacing: 20) {
                ForEach(library.data.followedArtists) { CardLink(card: $0, width: 110) }
            }
            .padding()
        }
        .overlay { if library.data.followedArtists.isEmpty { ContentUnavailableView("No artists", systemImage: "music.microphone", description: Text("Follow artists from their page.")) } }
        .navigationTitle("Artists")
    }
}

/// The signed-in account's YouTube Music library: Liked music and the playlists and albums in it.
struct AccountMusicLibrarySection: View {
    @Environment(AccountModel.self) private var account
    @State private var playlists: [MusicCard] = []
    @State private var albums: [MusicCard] = []
    @State private var loadStamp: LoadStamp?

    var body: some View {
        Section {
            NavigationLink(value: Route.playlist("VLLM")) {
                Label { Text("Liked music") } icon: {
                    Image(systemName: "hand.thumbsup.fill").foregroundStyle(.white).frame(width: 30, height: 30)
                        .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            ForEach(playlists + albums) { card in
                NavigationLink(value: card.route ?? .playlist(card.id)) {
                    HStack(spacing: 12) {
                        Artwork(url: card.artwork, cornerRadius: 8).frame(width: 52, height: 52)
                        VStack(alignment: .leading) {
                            Text(card.title).lineLimit(1)
                            Text(card.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        } header: {
            Label(account.active?.name ?? String(localized: "YouTube Music"), systemImage: "person.crop.circle")
        }
        .task(id: account.active?.id) {
            let key = account.active?.id.uuidString ?? ""
            guard loadStamp?.isFresh(for: key) != true else { return }
            // Another account's playlists must not stay under this account's name while it loads.
            if let stamp = loadStamp, stamp.key != key { playlists = []; albums = []; loadStamp = nil }
            async let p = try? AccountAPI.libraryPlaylists()
            async let a = try? AccountAPI.libraryAlbums()
            let (newPlaylists, newAlbums) = await (p ?? [], a ?? [])
            // Cancelled (the screen was left, or the account switched): keep what is shown.
            guard !Task.isCancelled else { return }
            playlists = newPlaylists
            albums = newAlbums
            if !(playlists + albums).isEmpty { loadStamp = LoadStamp(key: key) }
        }
    }
}
