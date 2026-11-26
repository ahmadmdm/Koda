import SwiftUI

/// The quality choice for downloading a video: what the video offers, with an estimated size.
struct VideoDownloadSheet: View {
    var video: Video
    @Environment(\.dismiss) private var dismiss
    @State private var options: [VideoDownloadOption] = []
    @State private var loading = true
    @State private var error: String?

    private var downloads: VideoDownloadManager { .shared }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options) { option in
                        Button {
                            downloads.start(video, option: option)
                            dismiss()
                        } label: {
                            HStack {
                                Label {
                                    Text(option.title)
                                    if let fps = option.frameRate, fps > 31 { Text(verbatim: "\(Int(fps.rounded())) fps").font(.caption).foregroundStyle(.secondary) }
                                } icon: { Image(systemName: option.isAudioOnly ? "headphones" : "film") }
                                Spacer()
                                if let bytes = option.estimatedBytes, bytes > 0 {
                                    Text("≈ \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text(video.title).lineLimit(2).textCase(nil)
                } footer: {
                    if !options.isEmpty { Text("Downloads play without a connection. Sizes are estimates.") }
                }
            }
            .overlay {
                if loading { LoadingView() }
                else if let error { ErrorView(message: error) { Task { await load() } } }
            }
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        loading = true; error = nil
        do { options = try await downloads.options(for: video) } catch { self.error = error.localizedDescription }
        loading = false
    }
}

/// The watch page's download button: Download, the progress while it runs, then Downloaded.
struct VideoDownloadButton: View {
    var video: Video
    @State private var choosing = false
    @State private var confirmCancel = false
    @State private var confirmDelete = false

    private var downloads: VideoDownloadManager { .shared }

    var body: some View {
        Group {
            if let item = downloads.items.first(where: { $0.id == video.id }) {
                Menu {
                    VideoExportButtons(item: item)
                    Divider()
                    Button("Remove Download", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { label }
            } else {
                Button {
                    if downloads.isInProgress(video.id) { confirmCancel = true } else { choosing = true }
                } label: { label }
            }
        }
        .sheet(isPresented: $choosing) { VideoDownloadSheet(video: video) }
        .confirmationDialog("Cancel this download?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel Download", role: .destructive) { downloads.cancel(video.id) }
            Button("Keep Downloading", role: .cancel) {}
        }
        .confirmationDialog("Remove this download?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { downloads.delete(video.id) }
        } message: { Text("The video will need a connection to play again.") }
    }

    @ViewBuilder private var label: some View {
        if let item = downloads.items.first(where: { $0.id == video.id }) {
            Label(item.isAudioOnly ? String(localized: "Downloaded (audio)") : String(localized: "Downloaded \(item.quality)"),
                  systemImage: "arrow.down.circle.fill")
        } else {
            switch downloads.states[video.id] {
            case .preparing:
                Label { Text("Preparing…") } icon: { ProgressView().controlSize(.mini) }
            case .downloading(let p):
                Label { Text(p, format: .percent.precision(.fractionLength(0))).monospacedDigit() } icon: {
                    ZStack {
                        Circle().stroke(.tint.opacity(0.25), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(p, 0.02)).stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 16, height: 16)
                    .animation(.linear(duration: 0.4), value: p)
                }
            case .failed:
                Label("Download failed", systemImage: "exclamationmark.arrow.circlepath")
            case nil:
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }
}

/// Save to Files and, for a video with picture, Save to Photos.
struct VideoExportButtons: View {
    var item: DownloadedVideo
    private var exporter: MediaExporter { .shared }

    var body: some View {
        Button("Save to Files…", systemImage: "folder") { exporter.save(item, to: .files) }
            .disabled(exporter.isBusy)
        if !item.isAudioOnly {
            Button("Save to Photos", systemImage: "photo.on.rectangle") { exporter.save(item, to: .photos) }
                .disabled(exporter.isBusy)
        }
    }
}

/// Downloaded videos, and the ones still downloading.
struct VideoDownloadsView: View {
    private var downloads: VideoDownloadManager { .shared }

    var body: some View {
        let videos = downloads.items.map(\.video)
        List {
            if !downloads.inProgress.isEmpty {
                Section("In progress") {
                    ForEach(downloads.inProgress, id: \.video.id) { p in
                        HStack(spacing: 12) {
                            Artwork(url: p.video.thumbnailURL, cornerRadius: 8, placeholderIcon: "play.rectangle").frame(width: 80, height: 45)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.video.title).font(.subheadline).lineLimit(1)
                                switch downloads.states[p.video.id] {
                                case .downloading(let value):
                                    ProgressView(value: value)
                                    Text("\(p.isAudioOnly ? String(localized: "Audio only") : p.quality) • \(value.formatted(.percent.precision(.fractionLength(0))))")
                                        .font(.caption).foregroundStyle(.secondary)
                                case .failed(let message): Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                                default: Text("Preparing…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if case .failed = downloads.states[p.video.id] {
                                Button { downloads.retry(p.video) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.glass)
                                    .accessibilityLabel("Retry Download")
                            }
                            Button { downloads.cancel(p.video.id) } label: { Image(systemName: "xmark") }.buttonStyle(.glass)
                                .accessibilityLabel("Cancel Download")
                        }
                    }
                }
            }
            Section {
                ForEach(downloads.items) { item in
                    VideoCard(video: item.video, compact: true, queue: videos,
                              caption: "\(item.isAudioOnly ? String(localized: "Audio only") : item.quality) • \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                        .swipeActions(edge: .trailing) {
                            Button("Remove Download", systemImage: "trash", role: .destructive) { downloads.delete(item.id) }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Save to Files…", systemImage: "folder") { MediaExporter.shared.save(item, to: .files) }.tint(.blue)
                            if !item.isAudioOnly {
                                Button("Save to Photos", systemImage: "photo.on.rectangle") { MediaExporter.shared.save(item, to: .photos) }.tint(.orange)
                            }
                        }
                }
            } footer: {
                if !downloads.items.isEmpty {
                    Text("\(downloads.items.count) videos • \(ByteCountFormatter.string(fromByteCount: downloads.totalBytes, countStyle: .file)) on this iPhone")
                }
            }
        }
        .listStyle(.plain)
        .readableContentWidth()
        .overlay {
            if downloads.items.isEmpty && downloads.inProgress.isEmpty {
                ContentUnavailableView("No downloads", systemImage: "arrow.down.circle", description: Text("Downloaded videos play without a connection. Download one from its page or its menu."))
            }
        }
        .navigationTitle("Downloaded videos")
    }
}
