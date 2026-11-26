import AVFoundation
import Foundation
import os

/// Keeps A! running in the background while a Cast session is up.
///
/// The receiver streams through the app: video segments always come from `CastProxyServer`, and music
/// needs the app to queue the next songs. iOS suspends an app a few seconds after it leaves the screen
/// unless it is playing audio, and the phone's own player is paused while the TV plays. So while
/// casting, a silent loop plays locally; it holds the audio background mode, and with it the proxy
/// and the Cast session, until casting ends.
@MainActor
enum CastBackgroundKeeper {
    private static var player: AVAudioPlayer?

    static func start() {
        guard player == nil else {
            if player?.isPlaying == false { player?.play() }
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            try session.setActive(true)
            let silence = try AVAudioPlayer(data: silentWAV(seconds: 2))
            silence.numberOfLoops = -1
            silence.volume = 0
            silence.prepareToPlay()
            silence.play()
            player = silence
            castLog.info("background keeper started")
        } catch {
            castLog.error("background keeper failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func stop() {
        guard let player else { return }
        player.stop()
        self.player = nil
        castLog.info("background keeper stopped")
    }

    /// After an interruption (a call) iOS stops every player; casting goes on, so does the loop.
    static func resumeIfNeeded() {
        guard let player, !player.isPlaying else { return }
        player.play()
    }

    /// A mono 16-bit PCM WAV of zeros.
    private static func silentWAV(seconds: Int) -> Data {
        let rate = 8000, bytesPerSample = 2
        let dataSize = rate * seconds * bytesPerSample
        var d = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + dataSize))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(UInt32(rate)); le(UInt32(rate * bytesPerSample)); le(UInt16(bytesPerSample)); le(UInt16(16))
        d.append(contentsOf: Array("data".utf8)); le(UInt32(dataSize))
        d.append(Data(count: dataSize))
        return d
    }
}
