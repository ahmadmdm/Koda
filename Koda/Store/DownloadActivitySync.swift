import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the video download Live Activity: one activity for all the downloads
/// running together. `VideoDownloadManager` calls `refresh` whenever a download's state changes.
///
/// HLS downloads go on in the system's background session while Koda is suspended, and a suspended
/// app can't update its activity. So the activity carries an estimated end, from the rate measured
/// while Koda ran, and the widget runs the progress bar and the time left on the clock. Just before
/// Koda goes to the background it sends one last update with a fresh estimate; when the session wakes
/// it with events (progress after a relaunch, a finished download), the activity is updated or ended.
@MainActor
enum DownloadActivitySync {
    typealias State = DownloadActivityAttributes.ContentState

    /// A download taking part in the activity. Finished and failed ones stay until the activity ends,
    /// so the overall progress doesn't jump back when one finishes.
    nonisolated private struct Member: Codable {
        enum Outcome: String, Codable { case finished, failed }
        var title: String
        var quality: String
        var thumbnail: URL?
        /// The size picked in the quality sheet; nil when the video didn't say.
        var bytes: Int64?
        var fraction: Double
        var outcome: Outcome?
        var order: Int
    }

    /// Updates at most this often while only the percentage changes.
    private static let minimumInterval: TimeInterval = 2
    /// No new bytes for this long while Koda runs: show the downloads as waiting.
    private static let waitingAfter: TimeInterval = 20
    private static let membersKey = "downloadActivityMembers"

    private static var members: [String: Member] = loadMembers()
    private static var nextOrder = (members.values.map(\.order).max() ?? 0) + 1
    private static var activityId: String?
    private static var lastSent: State?
    private static var lastSentAt = Date.distantPast
    private static var sending: Task<Void, Never>?
    /// The user swiped the activity away: don't bring it back until this set of downloads is over.
    private static var dismissed = false
    private static var adopted = false
    private static var observing = false
    /// Bytes done over the last half minute, for the rate.
    private static var samples: [(date: Date, bytes: Int64)] = []
    private static var lastProgressAt = Date.now
    private static var artworkVideoId: String?
    private static var artworkLoading: String?

    // MARK: From the download manager

    /// Folds the manager's states into the activity's downloads and updates the activity when
    /// something it shows changed (the percentage at most every two seconds).
    static func refresh(_ manager: VideoDownloadManager, force: Bool = false) {
        setUp()
        var changedMembers = false
        for (id, state) in manager.states {
            // iOS shows its own progress (Dynamic Island and Lock Screen, with a stop button) for
            // HLS downloads in the background asset session; a second activity would only repeat it.
            // Audio-only downloads are plain ranged fetches with no system UI, so those get ours.
            guard manager.pending[id]?.isAudioOnly == true || members[id] != nil else { continue }
            switch state {
            case .preparing, .downloading:
                let fraction: Double = if case .downloading(let p) = state { p } else { 0 }
                if var member = members[id] {
                    if member.outcome != nil {
                        // Tried again.
                        member.outcome = nil
                        member.fraction = 0
                        changedMembers = true
                    }
                    if fraction > member.fraction { member.fraction = fraction }
                    members[id] = member
                } else if let pending = manager.pending[id] {
                    members[id] = Member(title: pending.video.title, quality: pending.quality, thumbnail: pending.video.thumbnailURL,
                                         bytes: pending.estimatedBytes, fraction: fraction, order: nextOrder)
                    nextOrder += 1
                    changedMembers = true
                }
            case .failed:
                if members[id] != nil, members[id]?.outcome != .failed {
                    members[id]?.outcome = .failed
                    changedMembers = true
                }
            }
        }
        for id in members.keys where manager.states[id] == nil && members[id]?.outcome != .failed {
            if manager.isDownloaded(id) {
                if members[id]?.outcome != .finished {
                    members[id]?.outcome = .finished
                    members[id]?.fraction = 1
                    saveMembers()
                }
            } else if manager.pending[id] == nil {
                // Cancelled: it no longer counts.
                members[id] = nil
                changedMembers = true
            }
        }
        if changedMembers {
            samples.removeAll()
            saveMembers()
        }
        update(force: force || changedMembers)
    }

    /// Before the background session's completion handler: sends what the session's events changed.
    static func flush(_ manager: VideoDownloadManager) async {
        refresh(manager, force: true)
        await sending?.value
    }

    /// The Live Activity setting changed.
    static func settingChanged() {
        refresh(.shared, force: true)
    }

    // MARK: Activity

    private static var isEnabled: Bool { LiveActivitySync.isEnabled && ActivityAuthorizationInfo().areActivitiesEnabled }

    private static func update(force: Bool) {
        adoptExisting()
        let active = members.values.filter { $0.outcome == nil }
        guard !members.isEmpty else {
            // Everything was cancelled.
            endNow()
            return
        }
        guard isEnabled else {
            endNow()
            if active.isEmpty { reset() }
            return
        }
        if active.isEmpty {
            finish()
            return
        }
        let state = makeState()
        if let id = activityId, let activity = Activity<DownloadActivityAttributes>.activities.first(where: { $0.id == id }) {
            guard activity.activityState == .active || activity.activityState == .stale else {
                // Swiped away from the Lock Screen.
                activityId = nil
                dismissed = true
                return
            }
            guard force || shouldSend(state) else { return }
            send(id, state)
            return
        }
        guard !dismissed else { return }
        // Only possible while Koda is in the foreground; a download that starts in the background waits.
        guard let activity = try? Activity.request(attributes: DownloadActivityAttributes(),
                                                   content: content(state), pushType: nil) else { return }
        activityId = activity.id
        lastSent = state
        lastSentAt = .now
    }

    /// Every download is over: show "Downloaded" (or the failure) for a few seconds, then go.
    private static func finish() {
        let state = makeState()
        let id = activityId
        reset()
        guard let id else { return }
        let seconds: TimeInterval = state.phase == .failed ? 8 : 4
        let final = ActivityContent(state: state, staleDate: nil)
        track { await end(id, final, dismissal: .after(.now.addingTimeInterval(seconds))) }
    }

    private static func endNow() {
        if members.isEmpty { reset() }
        guard let id = activityId else { return }
        activityId = nil
        lastSent = nil
        track { await end(id, nil, dismissal: .immediate) }
    }

    private static func reset() {
        if !members.isEmpty {
            members = [:]
            saveMembers()
        }
        samples.removeAll()
        dismissed = false
        activityId = nil
        lastSent = nil
    }

    private static func send(_ id: String, _ state: State) {
        lastSent = state
        lastSentAt = .now
        let content = content(state)
        track { await push(id, content) }
    }

    /// Keeps Koda awake until the system has the update: it may be on its way to suspension.
    private static func track(_ work: @escaping @MainActor () async -> Void) {
        let previous = sending
        let background = UIApplication.shared.beginBackgroundTask(withName: "Download Live Activity")
        sending = Task {
            await previous?.value
            await work()
            UIApplication.shared.endBackgroundTask(background)
        }
    }

    private static func content(_ state: State) -> ActivityContent<State> {
        // Past the estimate with no word from Koda, the widget says it's finishing rather than counting on.
        ActivityContent(state: state, staleDate: state.estimatedEnd.map { $0.addingTimeInterval(90) })
    }

    private static func shouldSend(_ state: State) -> Bool {
        guard let old = lastSent else { return true }
        if old.phase != state.phase || old.videoId != state.videoId || old.activeCount != state.activeCount
            || old.finishedCount != state.finishedCount || old.failedCount != state.failedCount
            || old.artworkVideoId != state.artworkVideoId || old.quality != state.quality
            || (old.estimatedEnd == nil) != (state.estimatedEnd == nil) { return true }
        return Int(old.fraction * 100) != Int(state.fraction * 100) && Date.now.timeIntervalSince(lastSentAt) >= minimumInterval
    }

    // MARK: State

    private static func makeState(suspending: Bool = false) -> State {
        let all = members.sorted { $0.value.order < $1.value.order }
        let active = all.filter { $0.value.outcome == nil }
        let finished = all.filter { $0.value.outcome == .finished }.count
        let failed = all.filter { $0.value.outcome == .failed }.count
        // Downloads whose size isn't known count as an average one.
        let known = all.compactMap(\.value.bytes).filter { $0 > 0 }
        let fallback = known.isEmpty ? 100_000_000 : known.reduce(0, +) / Int64(known.count)
        var total: Int64 = 0, done: Int64 = 0
        for (_, member) in all where member.outcome != .failed {
            let bytes = member.bytes.flatMap { $0 > 0 ? $0 : nil } ?? fallback
            total += bytes
            done += Int64(Double(bytes) * min(max(member.fraction, 0), 1))
        }
        let now = Date.now
        if samples.last?.bytes != done { lastProgressAt = now }
        if samples.last.map({ now.timeIntervalSince($0.date) >= 1 }) ?? true {
            samples.append((now, done))
            samples.removeAll { now.timeIntervalSince($0.date) > 30 }
        }
        // Once all are done, the video whose thumbnail is already written, so the last frame has a picture.
        let finishedShown = all.first { $0.key == artworkVideoId && $0.value.outcome == .finished }
            ?? all.last { $0.value.outcome == .finished }
        guard let shown = active.first ?? finishedShown ?? all.last else {
            return State(phase: .failed, videoId: "", title: "", quality: "", activeCount: 0, finishedCount: 0, failedCount: 0,
                         fraction: 0, bytesDone: 0, bytesTotal: 0, capturedAt: now)
        }
        let phase: State.Phase
        if !active.isEmpty {
            // Audio-only downloads run in Koda and stop once it's suspended.
            let backgroundable = active.contains { $0.value.quality != "Audio" }
            phase = (suspending && !backgroundable) || now.timeIntervalSince(lastProgressAt) > waitingAfter ? .waiting : .downloading
        } else {
            phase = finished > 0 ? .finished : .failed
        }
        if shown.key != artworkVideoId { loadArtwork(shown.key, from: shown.value.thumbnail) }
        return State(phase: phase, videoId: shown.key, title: shown.value.title, quality: shown.value.quality,
                     activeCount: active.count, finishedCount: finished, failedCount: failed,
                     fraction: total > 0 ? Double(done) / Double(total) : 0, bytesDone: done, bytesTotal: total,
                     capturedAt: now, estimatedEnd: phase == .downloading ? estimatedEnd(remaining: total - done, now: now) : nil,
                     artworkVideoId: artworkVideoId)
    }

    /// From the rate over the last half minute; the estimate sent before while there's no new one yet
    /// (just after a relaunch).
    private static func estimatedEnd(remaining: Int64, now: Date) -> Date? {
        if let first = samples.first, let last = samples.last, last.date.timeIntervalSince(first.date) >= 4 {
            let rate = Double(last.bytes - first.bytes) / last.date.timeIntervalSince(first.date)
            if rate > 0 { return now.addingTimeInterval(max(Double(remaining) / rate, 1)) }
            return nil
        }
        if let previous = lastSent?.estimatedEnd, previous > now { return previous }
        return nil
    }

    // MARK: Lifecycle

    private static func setUp() {
        guard !observing else { return }
        observing = true
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { willSuspend() }
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refresh(.shared, force: true) }
        }
    }

    /// Koda is about to be suspended: one last update with a fresh estimate, so the activity runs
    /// on its own until the session wakes Koda again.
    private static func willSuspend() {
        guard isEnabled, let id = activityId, members.values.contains(where: { $0.outcome == nil }) else { return }
        send(id, makeState(suspending: true))
    }

    /// After a relaunch (for example by the background session), keep the activity the previous run
    /// left and end any extras.
    private static func adoptExisting() {
        guard !adopted else { return }
        adopted = true
        let existing = Activity<DownloadActivityAttributes>.activities
        if let first = existing.first {
            activityId = first.id
            lastSent = first.content.state
            artworkVideoId = first.content.state.artworkVideoId
        } else if members.values.allSatisfy({ $0.outcome != nil }) {
            reset()
        }
        for activity in existing.dropFirst() {
            let id = activity.id
            track { await end(id, nil, dismissal: .immediate) }
        }
    }

    /// Activities aren't Sendable, so they're looked up again off the main actor.
    nonisolated private static func push(_ id: String, _ content: ActivityContent<State>) async {
        for activity in Activity<DownloadActivityAttributes>.activities where activity.id == id {
            await activity.update(content)
        }
    }

    nonisolated private static func end(_ id: String, _ content: ActivityContent<State>?, dismissal: ActivityUIDismissalPolicy) async {
        for activity in Activity<DownloadActivityAttributes>.activities where activity.id == id {
            await activity.end(content, dismissalPolicy: dismissal)
        }
    }

    // MARK: Thumbnail

    /// Writes the video's thumbnail for the activity: a small 16:9 JPEG.
    /// Tried once per video: a thumbnail that doesn't load leaves the placeholder.
    private static func loadArtwork(_ videoId: String, from url: URL?) {
        guard artworkLoading != videoId, let url, let file = NowPlayingSnapshot.downloadArtworkURL else { return }
        artworkLoading = videoId
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url), await writeArtwork(data, to: file),
                  artworkLoading == videoId else { return }
            artworkVideoId = videoId
            update(force: false)
        }
    }

    @concurrent
    nonisolated private static func writeArtwork(_ data: Data, to url: URL) async -> Bool {
        guard let original = UIImage(data: data) else { return false }
        let image = VideoPlayerModel.removingLetterbox(original)
        let size = CGSize(width: 200, height: 112)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let scale = max(size.width / image.size.width, size.height / image.size.height)
            let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
        }
        return (try? scaled.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)) != nil
    }

    // MARK: Persistence

    /// Kept across launches, so the overall progress still counts the downloads that finished before
    /// the system relaunched Koda.
    private static func loadMembers() -> [String: Member] {
        guard let data = UserDefaults.standard.data(forKey: membersKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Member].self, from: data)) ?? [:]
    }

    private static func saveMembers() {
        if members.isEmpty {
            UserDefaults.standard.removeObject(forKey: membersKey)
        } else if let data = try? JSONEncoder().encode(members) {
            UserDefaults.standard.set(data, forKey: membersKey)
        }
    }
}
