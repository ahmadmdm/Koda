import SwiftUI
import UniformTypeIdentifiers

/// Library › On this iPhone: the row that opens the imported files, and an import button.
struct LocalMusicSection: View {
    @State private var local = LocalMusicLibrary.shared
    @State private var showImporter = false

    var body: some View {
        Section("On this iPhone") {
            NavigationLink { LocalMusicView() } label: {
                HStack {
                    Label { Text("Music files") } icon: {
                        Image(systemName: "iphone").foregroundStyle(.white).frame(width: 30, height: 30)
                            .background(Color.gray.gradient, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                    if !local.songs.isEmpty { Text(local.songs.count, format: .number).foregroundStyle(.secondary).monospacedDigit() }
                }
            }
            Button("Import audio files…", systemImage: "square.and.arrow.down") { showImporter = true }
        }
        .localMusicImporter(isPresented: $showImporter)
    }
}

/// Audio files imported from Files or dropped into Koda's folder with the Files app or Finder.
struct LocalMusicView: View {
    @Environment(MusicPlayer.self) private var player
    @State private var local = LocalMusicLibrary.shared
    @State private var query = ""
    @State private var showImporter = false

    var body: some View {
        let songs = filtered
        List {
            if !local.songs.isEmpty {
                CollectionActions(songs: songs).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            Section {
                ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                    SongRow(song: song) { player.play(songs, startAt: i) }
                }
                .onDelete { idx in idx.map { songs[$0] }.forEach(local.delete) }
            } footer: {
                if !local.songs.isEmpty {
                    Text("\(local.songs.count) files • \(ByteCountFormatter.string(fromByteCount: local.totalBytes, countStyle: .file))")
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if local.songs.isEmpty {
                ContentUnavailableView {
                    Label("No music files", systemImage: "music.note.house")
                } description: {
                    Text("Import MP3, M4A, AAC, WAV, FLAC or AIFF files, or copy them into the Koda › Music folder with the Files app or Finder.")
                } actions: {
                    Button("Import audio files…") { showImporter = true }.buttonStyle(.glassProminent)
                }
            } else if songs.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, prompt: "Search files")
        .navigationTitle("On this iPhone")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import", systemImage: "plus") { showImporter = true }
            }
        }
        .refreshable { await local.rescan() }
        .task { await local.rescan() }
        .localMusicImporter(isPresented: $showImporter)
    }

    private var filtered: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return local.songs }
        return local.songs.filter {
            $0.title.localizedCaseInsensitiveContains(q) || $0.artist.localizedCaseInsensitiveContains(q)
                || ($0.album?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}

private struct LocalMusicImporter: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.fileImporter(isPresented: $isPresented, allowedContentTypes: LocalMusicLibrary.contentTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                let added = await LocalMusicLibrary.shared.importFiles(urls)
                app.showToast(added == 1 ? "1 file imported" : "\(added) files imported")
            }
        }
    }
}

extension View {
    func localMusicImporter(isPresented: Binding<Bool>) -> some View {
        modifier(LocalMusicImporter(isPresented: isPresented))
    }
}
