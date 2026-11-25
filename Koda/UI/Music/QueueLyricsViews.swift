import SwiftUI

struct QueueView: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var player = player
        NavigationStack {
            List {
                if let current = player.current {
                    Section("Now Playing") {
                        SongRow(song: current) {}
                    }
                }
                Section {
                    ForEach(Array(player.upNext.enumerated()), id: \.element.id) { i, song in
                        SongRow(song: song) { player.jump(toUpNext: i) }
                    }
                    .onMove { player.move(from: $0, to: $1) }
                    .onDelete { player.removeFromUpNext(at: $0) }
                } header: {
                    HStack {
                        Text("Up Next")
                        Spacer()
                        Toggle(isOn: $player.radioEnabled) { Label("Autoplay radio", systemImage: "infinity") }
                            .toggleStyle(.button).buttonStyle(.glass).controlSize(.small)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Save", systemImage: "square.and.arrow.down") {
                        app.addToPlaylist = [player.current].compactMap { $0 } + player.upNext
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", systemImage: "trash") { player.clearUpNext() }
                }
            }
        }
    }
}

struct LyricsPanel: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.layoutDirection) private var layoutDirection
    @AppStorage("lyricsOffset") private var offset: Double = 0
    @AppStorage("lyricsSize") private var size: Double = 28
    @State private var lyrics: Lyrics?
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics, lyrics.isSynced {
                synced(lyrics.synced, source: lyrics.source)
            } else if let plain = lyrics?.plain {
                ScrollView {
                    Text(plain).font(.system(size: size * 0.75, weight: .semibold)).padding(24)
                        .multilineTextAlignment(alignment(for: plain))
                        .frame(maxWidth: .infinity, alignment: alignment(for: plain) == .leading ? .leading : .trailing)
                    Text("Lyrics from \(lyrics?.source ?? "")").font(.caption).foregroundStyle(.secondary).padding(.bottom)
                }
            } else {
                ContentUnavailableView("No lyrics", systemImage: "quote.bubble", description: Text("No provider has lyrics for this song yet."))
            }
        }
        .frame(maxHeight: .infinity)
        .task(id: player.current?.id) {
            guard let song = player.current else { return }
            loading = true
            lyrics = await LyricsService.lyrics(for: song, duration: player.duration > 0 ? player.duration : nil)
            loading = false
        }
    }

    private func alignment(for text: String) -> TextAlignment {
        text.isRightToLeft == (layoutDirection == .rightToLeft) ? .leading : .trailing
    }

    private func synced(_ lines: [LyricLine], source: String) -> some View {
        let t = player.currentTime + offset
        let active = lines.lastIndex { $0.time <= t } ?? -1
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 120)
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: size, weight: .bold))
                            .multilineTextAlignment(alignment(for: line.text))
                            .frame(maxWidth: .infinity, alignment: alignment(for: line.text) == .leading ? .leading : .trailing)
                            .foregroundStyle(line.id == active ? .primary : .secondary)
                            .opacity(line.id == active ? 1 : (line.id < active ? 0.45 : 0.6))
                            .scaleEffect(line.id == active ? 1.0 : 0.96, anchor: .center)
                            .blur(radius: abs(line.id - active) > 2 ? 0.6 : 0)
                            .animation(.spring(duration: 0.4), value: active)
                            .id(line.id)
                            .onTapGesture { player.seek(to: line.time - offset) }
                    }
                    Text("Lyrics from \(source)").font(.caption).foregroundStyle(.secondary)
                    Color.clear.frame(height: 200)
                }
                .padding(.horizontal, 26)
            }
            .onChange(of: active) { _, new in
                withAnimation(.smooth(duration: 0.5)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.3)) }
            }
            .overlay(alignment: .topTrailing) {
                Menu {
                    Section("Timing") {
                        Button("Earlier 0.5s", systemImage: "minus") { offset -= 0.5 }
                        Button("Later 0.5s", systemImage: "plus") { offset += 0.5 }
                        Button("Reset (\(String(format: "%+.1f", offset))s)") { offset = 0 }
                    }
                    Section("Size") {
                        Button("Larger", systemImage: "textformat.size.larger") { size = min(size + 2, 44) }
                        Button("Smaller", systemImage: "textformat.size.smaller") { size = max(size - 2, 18) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 40, height: 40)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .padding(.trailing, 16)
            }
        }
    }
}

extension String {
    /// True when the first strong character is Arabic or Hebrew.
    var isRightToLeft: Bool {
        for scalar in unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return true
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x024F: return false
            default: continue
            }
        }
        return false
    }
}
