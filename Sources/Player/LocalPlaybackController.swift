import Foundation
import AVFoundation
import SwiftUI
import UIKit

/// Plays media the user owns, from the app sandbox.
///
/// Everything the embedded YouTube player is not allowed to do lives here: horizontal mirroring,
/// frame-accurate stepping, compositing a live camera over the frame, and muxing the audio into a
/// recorded take. That is not a coincidence — it is the whole reason the app has two engines.
final class LocalPlaybackController: PlaybackController {

    let player = AVPlayer()
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var bufferObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var pendingRate: Double = 1.0

    private(set) var currentURL: URL?
    @Published private(set) var naturalSize: CGSize = .zero

    override var capabilities: PlaybackCapabilities { .ownedMedia }
    override var sourceLabel: String { "Your library" }

    override init() {
        super.init()
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = false
        isMirrored = false
        installTimeObserver()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: - Loading

    func load(url: URL, autoplay: Bool = false) {
        currentURL = url
        publish(ready: false)
        publish(problem: nil)

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        // Music pitch-corrected at 0.5x is the difference between a usable slow practice and an
        // unlistenable one. `spectral` is the expensive-but-correct choice for music.
        item.audioTimePitchAlgorithm = .spectral

        observe(item: item)
        player.replaceCurrentItem(with: item)

        Task { [weak self] in
            guard let self else { return }
            let loadedDuration = (try? await asset.load(.duration)) ?? .zero
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            var size = CGSize.zero
            if let track = tracks.first {
                let natural = (try? await track.load(.naturalSize)) ?? .zero
                let transform = (try? await track.load(.preferredTransform)) ?? .identity
                let applied = natural.applying(transform)
                size = CGSize(width: abs(applied.width), height: abs(applied.height))
            }
            await MainActor.run {
                self.naturalSize = size
                if loadedDuration.isNumeric {
                    self.publish(duration: CMTimeGetSeconds(loadedDuration))
                }
                self.publish(ready: true)
                if autoplay { self.play() }
            }
        }
    }

    private func observe(item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard let self else { return }
            if observed.status == .failed {
                self.publish(problem: .unsupportedMedia)
            }
        }
        bufferObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observed, _ in
            self?.publish(buffering: !observed.isPlaybackLikelyToKeepUp)
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Same edge as the YouTube engine: a loop whose end sits on the last frame reaches
            // "ended" before the periodic observer can wrap it.
            if let loop = self.loop, loop.isUsable {
                self.seek(to: loop.start)
                self.play()
            } else {
                self.reportReachedEnd()
            }
        }
    }

    private func installTimeObserver() {
        // 1/30s: fine enough that an A/B loop lands on the right beat, coarse enough not to
        // thrash SwiftUI at 0.25x speed.
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            self.publish(time: CMTimeGetSeconds(time))
            let playing = self.player.timeControlStatus == .playing
            if playing != self.isPlaying { self.publish(playing: playing) }
        }
    }

    // MARK: - Commands

    override func play() {
        configureSessionForPlayback()
        player.playImmediately(atRate: Float(pendingRate))
        publish(playing: true)
    }

    override func pause() {
        player.pause()
        publish(playing: false)
    }

    override func seek(to seconds: Double) {
        let clamped = max(0, duration > 0 ? min(seconds, duration) : seconds)
        let target = CMTime(seconds: clamped, preferredTimescale: 600)
        // Zero tolerance: marking an eight-count is useless if the seek lands on the nearest
        // keyframe half a second away.
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        publish(time: clamped)
    }

    override func setRate(_ newRate: Double) {
        pendingRate = newRate
        publish(rate: newRate)
        if player.timeControlStatus == .playing {
            player.rate = Float(newRate)
        }
    }

    override func stepFrames(_ count: Int) {
        guard let item = player.currentItem else { return }
        if count > 0 ? item.canStepForward : item.canStepBackward {
            pause()
            item.step(byCount: count)
            publish(time: CMTimeGetSeconds(player.currentTime()))
        }
    }

    override func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    override func teardown() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemStatusObservation = nil
        bufferObservation = nil
        publish(ready: false)
    }

    private func configureSessionForPlayback() {
        AudioSessionManager.shared.activatePlayback()
    }
}

// MARK: - Audio session

/// One place that owns the audio session category, because playback and recording want different
/// things and fighting over it mid-session is the classic way to get silent recordings.
final class AudioSessionManager {
    static let shared = AudioSessionManager()
    private init() {}

    private var currentMode: Mode = .idle

    enum Mode { case idle, playback, playAndRecord }

    func activatePlayback() {
        // `.playAndRecord` already plays. Dropping to `.playback` while the studio camera is armed
        // would cut the microphone out of the take the moment the reference starts.
        guard currentMode == .idle else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [])
        try? session.setActive(true)
        currentMode = .playback
    }

    /// Recording a take while the reference plays out loud means the microphone will hear the
    /// reference. `.defaultToSpeaker` plus `.videoRecording` mode gives us the platform's echo
    /// handling, and the studio defaults to muting the reference when the mic is armed.
    func activatePlayAndRecord() {
        guard currentMode != .playAndRecord else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord,
                                 mode: .videoRecording,
                                 options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try? session.setActive(true)
        currentMode = .playAndRecord
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        currentMode = .idle
    }
}

// MARK: - SwiftUI host

/// A plain `AVPlayerLayer` host. Mirroring is applied by the caller with `.scaleEffect(x: -1)`
/// rather than a layer transform so the same modifier mirrors the camera preview identically.
struct LocalPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        uiView.playerLayer.videoGravity = videoGravity
    }

    final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
