import Foundation
import Combine
import SwiftUI
import UIKit

/// Drives the Studio: one owned reference file, the camera, and the record-on-the-one flow.
final class StudioModel: ObservableObject {
    let player = LocalPlaybackController()
    let recorder = CameraRecorder()

    @Published private(set) var item: LibraryItem?
    @Published var layout: StudioLayout = .splitVertical
    @Published var ghostOpacity: Double = 0.45
    @Published var referenceAudioOn = true {
        didSet { player.setMuted(!referenceAudioOn) }
    }
    @Published var toast: String?

    let choreography: Choreography?
    private weak var store: AppStore?
    private var cancellables = Set<AnyCancellable>()
    private var clockStart: Date?
    private var didSetUp = false

    /// Where the reference was when capture began, and the loop being drilled — stored on the take
    /// so export can line the music up with the section that was actually danced.
    private var captureReferenceStart: Double = 0
    private var captureLoop: ABLoop?
    private var captureRate: Double = 1.0

    init(choreography: Choreography?) {
        self.choreography = choreography
    }

    var availableItems: [LibraryItem] {
        guard let store else { return [] }
        let videos = store.library.filter { $0.kind == .video }
        guard let choreography else { return videos }
        let linked = videos.filter { $0.choreographyID == choreography.id }
        return linked.isEmpty ? videos : linked
    }

    var needsCamera: Bool { layout != .referenceOnly }

    // MARK: - Lifecycle

    func setUp(store: AppStore, initialItem: LibraryItem?) {
        guard !didSetUp else { return }
        didSetUp = true
        self.store = store

        let settings = store.settings
        layout = settings.defaultLayout
        player.isMirrored = settings.mirrorByDefault
        player.setRate(settings.defaultSpeed)

        recorder.usesFrontCamera = settings.useFrontCamera
        recorder.micEnabled = settings.micEnabled
        recorder.saveMirrored = settings.saveTakesMirrored
        wireRecorder()

        if let item = initialItem ?? availableItems.first {
            select(item)
        }

        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwakeInStudio
        clockStart = Date()
        startCamera()
    }

    func tearDown() {
        if case .recording = recorder.state { recorder.stopRecording() }
        recorder.stopSession()
        player.teardown()
        AudioSessionManager.shared.deactivate()
        UIApplication.shared.isIdleTimerDisabled = false

        if let clockStart, let store, let id = practiceChoreographyID {
            store.recordPracticeTime(Date().timeIntervalSince(clockStart), for: id)
        }
        clockStart = nil
    }

    func select(_ newItem: LibraryItem) {
        item = newItem
        player.clearLoop()
        player.load(url: MediaStore.mediaURL(newItem.filename))
    }

    private var practiceChoreographyID: String? {
        item?.choreographyID ?? choreography?.id
    }

    // MARK: - Camera

    private func startCamera() {
        // Own the audio session ourselves; letting the capture session reconfigure it behind our
        // back is how you end up with a silent reference or a silent take.
        AudioSessionManager.shared.activatePlayAndRecord()
        recorder.session.automaticallyConfiguresApplicationAudioSession = false

        recorder.$permission
            .receive(on: DispatchQueue.main)
            .sink { [weak self] permission in
                switch permission {
                case .granted, .micDenied: self?.recorder.configureAndStart()
                default: break
                }
            }
            .store(in: &cancellables)
        recorder.requestPermissions()
    }

    private func wireRecorder() {
        // Recorder state changes are rare (a handful per take), so it is cheap to let them redraw
        // the Studio chrome that depends on them.
        recorder.$state
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        recorder.onCountdownTick = { remaining in
            Haptics.countBeat(isFinal: remaining == 1)
        }
        recorder.onCaptureStarted = { [weak self] in
            guard let self else { return }
            self.player.setMuted(!self.referenceAudioOn)
            self.player.play()
        }
        recorder.onFinished = { [weak self] url, duration in
            self?.saveTake(from: url, duration: duration)
        }
        player.onReachedEnd = { [weak self] in
            guard let self, case .recording = self.recorder.state else { return }
            self.recorder.stopRecording()
        }
    }

    // MARK: - Recording

    func recordButtonTapped() {
        switch recorder.state {
        case .recording:
            recorder.stopRecording()
            player.pause()
        case .countingDown:
            recorder.cancelCountdown()
        case .ready:
            startTake()
        case .idle, .failed:
            recorder.configureAndStart()
        default:
            break
        }
    }

    private func startTake() {
        guard let store, item != nil else { return }
        player.pause()

        let loop = (player.loop?.isUsable ?? false) ? player.loop : nil
        captureLoop = loop
        captureRate = player.rate
        captureReferenceStart = loop?.start ?? player.currentTime
        player.seek(to: captureReferenceStart)

        if let loop, store.settings.autoStopAtSectionEnd {
            let runs = Double(max(1, store.settings.loopCountBeforeStop))
            recorder.plannedDuration = loop.duration * runs / max(0.1, captureRate)
        } else {
            recorder.plannedDuration = nil
        }
        recorder.saveMirrored = store.settings.saveTakesMirrored
        recorder.startCountdown(seconds: store.settings.countdownSeconds)
    }

    private func saveTake(from scratchURL: URL, duration: TimeInterval) {
        player.pause()
        guard let store else { return }

        let destination = MediaStore.recordingURL(scratchURL.lastPathComponent)
        do {
            MediaStore.delete(destination)
            try FileManager.default.moveItem(at: scratchURL, to: destination)
        } catch {
            toast = "Couldn't save the take: \(error.localizedDescription)"
            return
        }

        let previous = store.recordings.filter { $0.libraryItemID == item?.id }.count
        let baseTitle = item?.title ?? choreography?.title ?? "Practice"
        let recording = Recording(
            title: "\(baseTitle) — take \(previous + 1)",
            filename: destination.lastPathComponent,
            durationSeconds: duration,
            choreographyID: practiceChoreographyID,
            libraryItemID: item?.id,
            sectionLabel: captureLoop.map { "\($0.start.shortTimecodeText)–\($0.end.shortTimecodeText)" },
            referenceRate: captureRate,
            wasMirrored: recorder.usesFrontCamera && store.settings.saveTakesMirrored,
            micEnabled: recorder.micEnabled,
            loopStart: captureReferenceStart,
            loopEnd: captureLoop?.end
        )
        store.addRecording(recording)
        Haptics.success()
        toast = "Take saved to Takes"
    }
}
