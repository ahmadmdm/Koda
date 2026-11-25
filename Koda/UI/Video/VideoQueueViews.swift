import SwiftUI

/// The viewer's video queue on the watch page, above Up next and Related.
struct VideoQueueSection: View {
    @Environment(VideoPlayerModel.self) private var model
    @State private var showEditor = false

    var body: some View {
        let queue = model.userQueue
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Queue").font(.headline)
                Text(queue.count, format: .number).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button { showEditor = true } label: { Label("Edit", systemImage: "arrow.up.arrow.down") }
                    .buttonStyle(.glass).controlSize(.small)
                Button(role: .destructive) { model.clearQueue() } label: { Label("Clear", systemImage: "trash") }
                    .buttonStyle(.glass).controlSize(.small)
            }
            ForEach(Array(queue.enumerated()), id: \.element.id) { index, video in
                row(video, index: index, count: queue.count)
            }
        }
        .sheet(isPresented: $showEditor) { VideoQueueEditor() }
    }

    private func row(_ video: Video, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            Button { model.playQueued(at: index) } label: { QueuedVideoLabel(video: video) }
                .buttonStyle(.plain)
            Button { model.removeFromQueue(at: IndexSet(integer: index)) } label: {
                Image(systemName: "xmark").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove")
        }
        .contextMenu {
            Button("Play Now", systemImage: "play.fill") { model.playQueued(at: index) }
            if index > 0 {
                Button("Move Up", systemImage: "arrow.up") { model.moveQueue(from: IndexSet(integer: index), to: index - 1) }
            }
            if index < count - 1 {
                Button("Move Down", systemImage: "arrow.down") { model.moveQueue(from: IndexSet(integer: index), to: index + 2) }
            }
            Button("Remove", systemImage: "minus.circle", role: .destructive) { model.removeFromQueue(at: IndexSet(integer: index)) }
        }
    }
}

/// Thumbnail, title and channel of a queued video.
struct QueuedVideoLabel: View {
    var video: Video

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Artwork(url: video.thumbnailURL, cornerRadius: 8, placeholderIcon: "play.rectangle")
                .frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: 3) {
                Text(video.title).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(video.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Reorder and remove queued videos.
struct VideoQueueEditor: View {
    @Environment(VideoPlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.userQueue) { QueuedVideoLabel(video: $0) }
                    .onMove { model.moveQueue(from: $0, to: $1) }
                    .onDelete { model.removeFromQueue(at: $0) }
            }
            .listStyle(.plain)
            .environment(\.editMode, .constant(.active))
            .overlay {
                if model.userQueue.isEmpty {
                    ContentUnavailableView("Queue is empty", systemImage: "list.bullet.rectangle",
                                           description: Text("Use Play Next or Add to Queue on any video."))
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Clear", role: .destructive) { model.clearQueue() }.disabled(model.userQueue.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
