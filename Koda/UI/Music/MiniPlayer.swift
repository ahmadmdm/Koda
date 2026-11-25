import AVFoundation
import SwiftUI

/// The Liquid Glass bottom accessory above the tab bar, Apple Music style.
struct MiniPlayer: View {
    @Environment(MusicPlayer.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: player.current?.artwork, cornerRadius: 6)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 0) {
                Text(player.current?.title ?? "Not Playing").font(.subheadline.weight(.semibold)).lineLimit(1)
                if placement != .inline {
                    Text(player.current?.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if player.isLoading {
                ProgressView().controlSize(.small).frame(width: 32)
            } else {
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                }
            }
            if placement != .inline {
                Button { player.next() } label: { Image(systemName: "forward.fill").font(.title3).frame(width: 32, height: 32) }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
    }
}

struct VideoMiniPlayer: View {
    @Environment(VideoPlayerModel.self) private var video

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: video.current?.thumbnailURL, cornerRadius: 6, placeholderIcon: "play.rectangle")
                .frame(width: 52, height: 30)
            Text(video.current?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            Button { video.isPlaying ? video.player.pause() : video.player.play() } label: {
                Image(systemName: video.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                    .contentTransition(.symbolEffect(.replace)).frame(width: 32, height: 32)
            }
            Button { video.close() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 32, height: 32) }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { video.isPresented = true }
    }
}
