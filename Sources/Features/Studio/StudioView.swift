import SwiftUI
import UIKit

/// Full-screen practice space for media the user owns. Phone propped on a mirror, dancer three
/// metres away: every control that matters mid-routine is big, and the record button is the one
/// saturated red thing on screen.
struct StudioView: View {
    let initialItem: LibraryItem?

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: StudioModel

    init(choreography: Choreography? = nil, item: LibraryItem? = nil) {
        self.initialItem = item
        _model = StateObject(wrappedValue: StudioModel(choreography: choreography))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            StudioStage(model: model, player: model.player, recorder: model.recorder,
                        showGrid: store.settings.showGridOverlay)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { model.setUp(store: store, initialItem: initialItem) }
        .onDisappear { model.tearDown() }
        .overlay(alignment: .top) { toastView }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Palette.surfaceRaised))
            }
            .accessibilityLabel("Close Studio")

            Menu {
                ForEach(model.availableItems) { item in
                    Button(item.title) { model.select(item) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.item?.title ?? "No video")
                        .lineLimit(1)
                    if model.availableItems.count > 1 {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Palette.primaryText)
            }
            .disabled(model.availableItems.count < 2)

            Spacer(minLength: 4)

            Menu {
                Picker("Layout", selection: $model.layout) {
                    ForEach(StudioLayout.allCases) { layout in
                        Label(layout.label, systemImage: layout.symbol).tag(layout)
                    }
                }
            } label: {
                chromeIcon(model.layout.symbol, active: false)
            }
            .accessibilityLabel("Layout")

            MirrorToggle(player: model.player)

            Button {
                Haptics.tap()
                model.recorder.flipCamera()
            } label: {
                chromeIcon("arrow.triangle.2.circlepath.camera", active: false)
            }
            .accessibilityLabel("Flip camera")
            .disabled(model.recorder.state.isBusy)
        }
        .foregroundColor(Palette.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func chromeIcon(_ symbol: String, active: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 40, height: 40)
            .foregroundColor(active ? Palette.ink : Palette.primaryText)
            .background(Circle().fill(active ? Palette.violet : Palette.surfaceRaised))
    }

    // MARK: - Bottom controls

    private var controls: some View {
        VStack(spacing: 12) {
            if model.layout == .ghostOverlay {
                HStack(spacing: 10) {
                    Image(systemName: "person.fill").font(.system(size: 12))
                    Slider(value: $model.ghostOpacity, in: 0.15...0.85)
                    Image(systemName: "figure.dance").font(.system(size: 12))
                }
                .foregroundColor(Palette.secondaryText)
            }

            TransportBar(controller: model.player,
                         availableSpeeds: PlaybackSpeed.allCases.map(\.rawValue),
                         compact: true)

            HStack(spacing: 14) {
                Button {
                    Haptics.tap()
                    model.referenceAudioOn.toggle()
                } label: {
                    chromeIcon(model.referenceAudioOn ? "speaker.wave.2.fill" : "speaker.slash.fill",
                               active: !model.referenceAudioOn)
                }
                .accessibilityLabel(model.referenceAudioOn ? "Mute reference" : "Unmute reference")

                Spacer()
                RecordButton(recorder: model.recorder, action: model.recordButtonTapped)
                Spacer()

                MicToggle(recorder: model.recorder)
            }
        }
        .padding(.horizontal, Metric.gutter)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Palette.ink)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(Palette.surfaceRaised))
                .padding(.top, 60)
                .transition(.opacity)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                        withAnimation { model.toast = nil }
                    }
                }
        }
    }
}

// MARK: - Stage

/// The picture area. Observes the player and recorder directly so a 30 Hz time tick redraws
/// only this subtree, not the whole Studio.
private struct StudioStage: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var player: LocalPlaybackController
    @ObservedObject var recorder: CameraRecorder
    var showGrid: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if model.item == nil {
                    EmptyStateView(
                        symbol: "film.stack",
                        title: "No video to practice with",
                        message: "Import a video you own in the Library tab, then open Studio from it."
                    )
                } else {
                    content(size: geo.size)
                }

                if case .countingDown(let n) = recorder.state {
                    Text("\(n)")
                        .font(.system(size: 140, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.6), radius: 12)
                        .transition(.scale.combined(with: .opacity))
                        .id(n)
                }
            }
            .animation(.easeOut(duration: 0.2), value: recorder.state)
        }
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        switch model.layout {
        case .referenceOnly:
            reference
        case .cameraOnly:
            camera
        case .splitVertical:
            VStack(spacing: 2) {
                reference.frame(height: size.height / 2)
                camera.frame(height: size.height / 2)
            }
        case .splitHorizontal:
            HStack(spacing: 2) {
                reference.frame(width: size.width / 2)
                camera.frame(width: size.width / 2)
            }
        case .ghostOverlay:
            ZStack {
                reference
                camera.opacity(model.ghostOpacity)
            }
        }
    }

    private var reference: some View {
        ZStack {
            LocalPlayerSurface(player: player.player)
                .mirrored(player.isMirrored)
            if showGrid { GridOverlay() }
            if let problem = player.problem {
                Text(problem.message)
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondaryText)
                    .padding()
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var camera: some View {
        ZStack(alignment: .topLeading) {
            switch recorder.permission {
            case .denied:
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.system(size: 26))
                    Text("Camera access is off")
                        .font(.system(size: 14, weight: .semibold))
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundColor(Palette.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                CameraPreview(session: recorder.session)
                if case .failed(let message) = recorder.state {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.amber)
                        .padding(8)
                }
            }

            if case .recording = recorder.state {
                HStack(spacing: 6) {
                    Circle().fill(Palette.record).frame(width: 8, height: 8)
                    Text(recorder.elapsed.shortTimecodeText).monospacedDigit()
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.6)))
                .padding(10)
            }
        }
        .clipped()
    }
}

/// Thirds plus a centre line — enough to check you're standing where the dancer stands.
private struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Small controls

private struct RecordButton: View {
    @ObservedObject var recorder: CameraRecorder
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.thud()
            action()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 4)
                    .frame(width: Metric.studioTapTarget + 16, height: Metric.studioTapTarget + 16)
                switch recorder.state {
                case .recording, .finishing:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Palette.record)
                        .frame(width: 30, height: 30)
                case .countingDown:
                    Image(systemName: "xmark")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(Palette.record)
                default:
                    Circle()
                        .fill(Palette.record)
                        .frame(width: Metric.studioTapTarget, height: Metric.studioTapTarget)
                }
            }
        }
        .disabled(recorder.state == .finishing || recorder.state == .configuring)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch recorder.state {
        case .recording: return "Stop recording"
        case .countingDown: return "Cancel countdown"
        default: return "Record a take"
        }
    }
}

private struct MirrorToggle: View {
    @ObservedObject var player: LocalPlaybackController

    var body: some View {
        Button {
            Haptics.tap()
            player.isMirrored.toggle()
        } label: {
            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundColor(player.isMirrored ? Palette.ink : Palette.primaryText)
                .background(Circle().fill(player.isMirrored ? Palette.violet : Palette.surfaceRaised))
        }
        .accessibilityLabel(player.isMirrored ? "Unmirror reference" : "Mirror reference")
    }
}

private struct MicToggle: View {
    @ObservedObject var recorder: CameraRecorder

    var body: some View {
        Button {
            Haptics.tap()
            recorder.setMicEnabled(!recorder.micEnabled)
        } label: {
            Image(systemName: recorder.micEnabled ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundColor(recorder.micEnabled ? Palette.primaryText : Palette.ink)
                .background(Circle().fill(recorder.micEnabled ? Palette.surfaceRaised : Palette.amber))
        }
        .disabled(recorder.state.isBusy || recorder.permission == .micDenied)
        .accessibilityLabel(recorder.micEnabled ? "Turn microphone off" : "Turn microphone on")
    }
}
