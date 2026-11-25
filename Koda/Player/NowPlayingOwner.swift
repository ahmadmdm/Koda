import MediaPlayer

/// Which player the system's Now Playing (Lock Screen, Control Center, Dynamic Island, the Live
/// Activity, widget buttons) belongs to. Each player claims it when it starts playing; only the owner
/// publishes `MPNowPlayingInfoCenter` and the Live Activity, and `MusicPlayer`'s remote command
/// targets forward to the video player while it owns playback.
@MainActor
enum NowPlayingOwner {
    enum Owner { case music, video }

    private(set) static var current: Owner = .music

    static var isVideo: Bool { current == .video }

    static func claim(_ owner: Owner) {
        guard owner != current else { return }
        current = owner
        // Music-only commands don't apply to a video; music gets them back when it claims again.
        let center = MPRemoteCommandCenter.shared()
        let music = owner == .music
        center.likeCommand.isEnabled = music
        center.changeShuffleModeCommand.isEnabled = music
        center.changeRepeatModeCommand.isEnabled = music
        if music {
            center.nextTrackCommand.isEnabled = true
            center.previousTrackCommand.isEnabled = true
        }
    }
}
