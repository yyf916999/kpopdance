import Foundation
import Combine

struct ABLoop: Equatable, Hashable {
    var start: Double
    var end: Double

    var duration: Double { max(0, end - start) }
    var isUsable: Bool { duration > 0.4 }
}

/// What a given playback source is allowed to do.
///
/// This is not a technical limitation dressed up as a feature — it is the rights model made
/// executable. Embedded YouTube playback legitimately supports speed and seeking through the
/// IFrame API, but mirroring, overlaying a camera on the frame, and capturing the audio are all
/// things the embed terms do not permit. Media the user owns has no such restriction. Encoding
/// that as capabilities means the UI can explain *why* a control is unavailable instead of
/// silently hiding it.
struct PlaybackCapabilities: OptionSet, Hashable {
    let rawValue: Int

    static let variableSpeed   = PlaybackCapabilities(rawValue: 1 << 0)
    static let abLoop          = PlaybackCapabilities(rawValue: 1 << 1)
    static let mirror          = PlaybackCapabilities(rawValue: 1 << 2)
    static let frameStep       = PlaybackCapabilities(rawValue: 1 << 3)
    static let cameraOverlay   = PlaybackCapabilities(rawValue: 1 << 4)
    static let audioCapture    = PlaybackCapabilities(rawValue: 1 << 5)
    static let preciseSeek     = PlaybackCapabilities(rawValue: 1 << 6)

    static let embeddedYouTube: PlaybackCapabilities = [.variableSpeed, .abLoop]
    static let ownedMedia: PlaybackCapabilities = [
        .variableSpeed, .abLoop, .mirror, .frameStep, .cameraOverlay, .audioCapture, .preciseSeek
    ]
}

enum PlaybackProblem: Equatable {
    case embeddingDisabled
    case notFound
    case network
    case unsupportedMedia
    case other(String)

    var message: String {
        switch self {
        case .embeddingDisabled:
            return "The uploader has turned off playback outside YouTube for this video."
        case .notFound:
            return "That video is no longer available. Try resolving a new reference."
        case .network:
            return "Couldn't reach YouTube. Check your connection."
        case .unsupportedMedia:
            return "This file's format can't be played."
        case .other(let text):
            return text
        }
    }

    var recoveryHint: String? {
        switch self {
        case .embeddingDisabled: return "Open it in the YouTube app, or pick a different reference video."
        case .notFound: return "Tap Re-resolve to search for the current upload."
        default: return nil
        }
    }
}

/// Shared transport surface over "a YouTube embed" and "a file on disk". Subclasses override the
/// command methods; the base owns the published state and the A/B loop enforcement so the loop
/// behaves identically no matter what is playing.
class PlaybackController: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Double = 1.0
    @Published private(set) var problem: PlaybackProblem?

    /// Mirror is view-level, but it lives here so the studio, the compare view and the recorder
    /// all read one value.
    @Published var isMirrored = false
    @Published var loop: ABLoop?
    @Published private(set) var completedLoops = 0

    /// Fires every time the playhead wraps from loop end back to loop start.
    var onLoopComplete: (() -> Void)?
    /// Fires when the media reaches its natural end.
    var onReachedEnd: (() -> Void)?

    var capabilities: PlaybackCapabilities { [] }
    var sourceLabel: String { "" }

    private var lastLoopFireTime: TimeInterval = 0

    var progressFraction: Double {
        duration > 0 ? min(1, max(0, currentTime / duration)) : 0
    }

    // MARK: - Commands (overridden)

    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
    func setRate(_ newRate: Double) {}
    func stepFrames(_ count: Int) {}
    func setMuted(_ muted: Bool) {}
    func teardown() {}

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func nudge(by seconds: Double) {
        seek(to: min(max(0, currentTime + seconds), max(0, duration)))
    }

    // MARK: - Loop helpers

    func setLoopStart(_ time: Double) {
        let end = loop?.end ?? duration
        loop = ABLoop(start: min(time, max(0, end - 0.5)), end: end)
        completedLoops = 0
    }

    func setLoopEnd(_ time: Double) {
        let start = loop?.start ?? 0
        loop = ABLoop(start: start, end: max(time, start + 0.5))
        completedLoops = 0
    }

    func clearLoop() {
        loop = nil
        completedLoops = 0
    }

    func applySection(_ section: PracticeSection) {
        loop = ABLoop(start: section.start, end: section.end)
        completedLoops = 0
        seek(to: section.start)
    }

    // MARK: - State plumbing for subclasses

    func publish(ready: Bool) { setOnMain { self.isReady = ready } }
    func publish(playing: Bool) { setOnMain { self.isPlaying = playing } }
    func publish(buffering: Bool) { setOnMain { self.isBuffering = buffering } }
    func publish(duration value: Double) {
        guard value.isFinite, value > 0 else { return }
        setOnMain { if abs(self.duration - value) > 0.05 { self.duration = value } }
    }
    func publish(rate value: Double) { setOnMain { self.rate = value } }
    func publish(problem value: PlaybackProblem?) { setOnMain { self.problem = value } }

    /// Subclasses funnel every playhead update through here so loop handling lives in one place.
    func publish(time value: Double) {
        setOnMain {
            self.currentTime = value
            self.enforceLoopIfNeeded(at: value)
        }
    }

    func reportReachedEnd() {
        setOnMain {
            self.isPlaying = false
            self.onReachedEnd?()
        }
    }

    private func enforceLoopIfNeeded(at time: Double) {
        guard let loop, loop.isUsable else { return }
        // A 60 ms lead-in compensates for the fact that neither engine reports the playhead
        // continuously; without it a fast section can overshoot the loop end by a beat.
        guard time >= loop.end - 0.06 else { return }
        // The seek is asynchronous in both engines, so a second tick can arrive before the
        // playhead actually moves. Debounce on wall clock rather than media time.
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastLoopFireTime > 0.35 else { return }
        lastLoopFireTime = now

        completedLoops += 1
        seek(to: loop.start)
        onLoopComplete?()
    }

    private func setOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

extension Double {
    /// mm:ss.d — the tenth matters when you are marking an eight-count boundary.
    var timecodeText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let tenths = Int((self - Double(total)) * 10)
        return String(format: "%d:%02d.%d", total / 60, total % 60, tenths)
    }

    var shortTimecodeText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
