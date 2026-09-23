import Foundation
import AVFoundation
import UIKit
import SwiftUI
import Combine

enum RecorderState: Equatable {
    case idle
    case configuring
    case ready
    case countingDown(Int)
    case recording
    case finishing
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .countingDown, .recording, .finishing: return true
        default: return false
        }
    }
}

enum CameraPermission: Equatable {
    case unknown
    case granted
    case denied
    case micDenied
}

/// Camera capture for practice takes.
///
/// Three things make this different from a generic "record a video" helper:
///
///  1. It starts and stops on the reference's schedule, not the user's thumb. You cannot tap a
///     record button, run to your mark and start dancing on the 1 — so the recorder owns a
///     countdown and an auto-stop tied to the loop the user is drilling.
///  2. It records mirrored by default. Dancers learn facing a mirror; a take that is flipped
///     relative to what they just saw is actively confusing to review.
///  3. It never touches the reference audio unless that audio is a file the user owns. The
///     music is muxed afterwards by `RecordingComposer`, never tapped from the player.
final class CameraRecorder: NSObject, ObservableObject {

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var permission: CameraPermission = .unknown
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var usesFrontCamera = true
    @Published var micEnabled = true

    /// Called with the finished file once writing completes.
    var onFinished: ((URL, TimeInterval) -> Void)?
    /// Called the instant capture actually begins, so the caller can start the reference in sync.
    var onCaptureStarted: (() -> Void)?
    var onCountdownTick: ((Int) -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.yufan.practiceroom.capture")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    private var countdownTimer: Timer?
    private var elapsedTimer: Timer?
    private var autoStopWorkItem: DispatchWorkItem?
    private var recordingStartedAt: Date?
    private var configured = false

    /// Set before `startCountdown` to have the recorder stop itself after this many seconds of
    /// captured footage. Nil means the user stops it manually.
    var plannedDuration: TimeInterval?
    /// Mirror the saved file to match what the dancer saw while recording.
    var saveMirrored = true

    // MARK: - Permissions

    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoGranted in
            guard let self else { return }
            guard videoGranted else {
                DispatchQueue.main.async { self.permission = .denied }
                return
            }
            guard self.micEnabled else {
                DispatchQueue.main.async { self.permission = .granted }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                DispatchQueue.main.async {
                    // A denied microphone is not fatal — silent takes are still useful for
                    // checking lines — so we downgrade rather than block.
                    self.permission = audioGranted ? .granted : .micDenied
                    if !audioGranted { self.micEnabled = false }
                }
            }
        }
    }

    // MARK: - Session lifecycle

    func configureAndStart() {
        guard !configured else {
            sessionQueue.async { [weak self] in
                guard let self, !self.session.isRunning else { return }
                self.session.startRunning()
            }
            return
        }
        setState(.configuring)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720

            do {
                try self.attachVideoInput()
                if self.micEnabled { try? self.attachAudioInput() }
                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                }
                self.session.commitConfiguration()
                self.applyConnectionSettings()
                self.session.startRunning()
                self.configured = true
                self.setState(.ready)
            } catch {
                self.session.commitConfiguration()
                self.setState(.failed("Couldn't start the camera: \(error.localizedDescription)"))
            }
        }
    }

    func stopSession() {
        cancelTimers()
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func attachVideoInput() throws {
        let position: AVCaptureDevice.Position = usesFrontCamera ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw NSError(domain: "PracticeRoom", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera available."])
        }
        // 30 fps keeps file sizes sane for long takes; dance review does not need 60.
        try? device.lockForConfiguration()
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first,
           range.minFrameRate <= 30, range.maxFrameRate >= 30 {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        }
        device.unlockForConfiguration()

        let input = try AVCaptureDeviceInput(device: device)
        if let existing = videoInput { session.removeInput(existing) }
        guard session.canAddInput(input) else {
            throw NSError(domain: "PracticeRoom", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Camera input rejected."])
        }
        session.addInput(input)
        videoInput = input
    }

    private func attachAudioInput() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else { return }
        let input = try AVCaptureDeviceInput(device: device)
        if let existing = audioInput { session.removeInput(existing) }
        guard session.canAddInput(input) else { return }
        session.addInput(input)
        audioInput = input
    }

    private func detachAudioInput() {
        guard let audioInput else { return }
        session.beginConfiguration()
        session.removeInput(audioInput)
        session.commitConfiguration()
        self.audioInput = nil
    }

    private func applyConnectionSettings() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = usesFrontCamera && saveMirrored
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .standard
        }
    }

    func flipCamera() {
        // Flip the published flag on main first, then reconfigure. Hopping back to main from the
        // session queue would be a sync deadlock waiting to happen.
        usesFrontCamera.toggle()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            try? self.attachVideoInput()
            self.session.commitConfiguration()
            self.applyConnectionSettings()
        }
    }

    func setMicEnabled(_ enabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { self.micEnabled = enabled }
            if enabled {
                self.session.beginConfiguration()
                try? self.attachAudioInput()
                self.session.commitConfiguration()
            } else {
                self.detachAudioInput()
            }
        }
    }

    // MARK: - Recording

    /// Counts the user in, then starts capture. `onCaptureStarted` fires at the exact moment the
    /// file starts receiving samples, which is when the caller should roll the reference video —
    /// that is what keeps the take and the music in sync without any clock arithmetic.
    func startCountdown(seconds: Int) {
        guard case .ready = state else {
            if case .idle = state { configureAndStart() }
            return
        }
        cancelTimers()

        guard seconds > 0 else {
            beginCapture()
            return
        }

        var remaining = seconds
        setState(.countingDown(remaining))
        onCountdownTick?(remaining)

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self.countdownTimer = nil
                self.beginCapture()
            } else {
                self.setState(.countingDown(remaining))
                self.onCountdownTick?(remaining)
            }
        }
        countdownTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func cancelCountdown() {
        cancelTimers()
        setState(.ready)
    }

    private func beginCapture() {
        applyConnectionSettings()
        let filename = "take-\(Int(Date().timeIntervalSince1970)).mov"
        let url = MediaStore.scratchDirectory.appendingPathComponent(filename)
        MediaStore.delete(url)

        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning else {
                self.setState(.failed("Camera isn't running."))
                return
            }
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        autoStopWorkItem?.cancel()
        autoStopWorkItem = nil
        guard movieOutput.isRecording else { return }
        setState(.finishing)
        sessionQueue.async { [weak self] in
            self?.movieOutput.stopRecording()
        }
    }

    private func scheduleAutoStopIfNeeded() {
        guard let plannedDuration, plannedDuration > 0.5 else { return }
        let work = DispatchWorkItem { [weak self] in self?.stopRecording() }
        autoStopWorkItem = work
        // A short tail keeps the last pose in frame instead of cutting on the final beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + plannedDuration + 0.6, execute: work)
    }

    private func startElapsedTimer() {
        recordingStartedAt = Date()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let started = self.recordingStartedAt else { return }
            self.elapsed = Date().timeIntervalSince(started)
        }
        elapsedTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelTimers() {
        countdownTimer?.invalidate(); countdownTimer = nil
        elapsedTimer?.invalidate(); elapsedTimer = nil
        autoStopWorkItem?.cancel(); autoStopWorkItem = nil
    }

    private func setState(_ newState: RecorderState) {
        DispatchQueue.main.async { self.state = newState }
    }
}

// MARK: - Capture delegate

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput,
                    didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.elapsed = 0
            self.state = .recording
            self.startElapsedTimer()
            self.scheduleAutoStopIfNeeded()
            // Roll the reference now, not when the button was tapped: the gap between the two is
            // where drift comes from.
            self.onCaptureStarted?()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        cancelTimers()
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        recordingStartedAt = nil

        DispatchQueue.main.async {
            // AVFoundation reports an error for a stop that still produced a usable file (for
            // example a session interruption). Trust the file, not the error, when both exist.
            let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
            if let error, !fileExists {
                self.state = .failed(error.localizedDescription)
                return
            }
            self.state = .ready
            self.onFinished?(outputFileURL, duration)
        }
    }
}

// MARK: - Preview

/// Live camera preview. The front-camera preview layer mirrors by default, which is exactly what
/// a dancer expects — you are standing in front of a mirror, not a camcorder.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = gravity
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        uiView.previewLayer.videoGravity = gravity
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
