import SwiftUI

/// Scrub bar that also draws the A/B loop region.
///
/// Seeking while a 0.25x loop is running is the single most-used gesture in the app, so the bar is
/// a 28pt-tall drag target rather than a hairline slider, and it reports drag start/end so the
/// caller can pause the engine instead of fighting it for the playhead.
struct ScrubBar: View {
    var currentTime: Double
    var duration: Double
    var loop: ABLoop?
    var onScrub: (Double) -> Void
    var onScrubStateChange: ((Bool) -> Void)?

    @State private var isDragging = false
    @State private var dragFraction: Double = 0

    private var fraction: Double {
        if isDragging { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, currentTime / duration))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.14))
                    .frame(height: 6)

                if let loop, duration > 0, loop.isUsable {
                    let start = min(1, max(0, loop.start / duration))
                    let end = min(1, max(0, loop.end / duration))
                    Capsule()
                        .fill(Palette.mint.opacity(0.35))
                        .frame(width: max(2, (end - start) * width), height: 6)
                        .offset(x: start * width)
                }

                Capsule().fill(Palette.accent)
                    .frame(width: max(2, fraction * width), height: 6)

                Circle()
                    .fill(Color.white)
                    .frame(width: isDragging ? 18 : 13, height: isDragging ? 18 : 13)
                    .shadow(radius: 3)
                    .offset(x: max(0, fraction * width - (isDragging ? 9 : 6.5)))
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onScrubStateChange?(true)
                        }
                        dragFraction = min(1, max(0, value.location.x / max(width, 1)))
                        onScrub(dragFraction * duration)
                    }
                    .onEnded { _ in
                        onScrub(dragFraction * duration)
                        isDragging = false
                        onScrubStateChange?(false)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 28)
    }
}

/// The full transport: play/pause, scrub, speed, A/B loop. Shared by the detail screen and the
/// studio so the muscle memory is identical in both.
struct TransportBar: View {
    @ObservedObject var controller: PlaybackController
    var availableSpeeds: [Double]
    var compact: Bool = false
    /// Invoked when the user taps a control the current source cannot do, so the caller can
    /// explain why rather than the button silently doing nothing.
    var onUnsupported: ((PlaybackCapabilities) -> Void)?

    @State private var wasPlayingBeforeScrub = false

    var body: some View {
        VStack(spacing: compact ? 8 : 12) {
            ScrubBar(
                currentTime: controller.currentTime,
                duration: controller.duration,
                loop: controller.loop,
                onScrub: { controller.seek(to: $0) },
                onScrubStateChange: { began in
                    if began {
                        wasPlayingBeforeScrub = controller.isPlaying
                        controller.pause()
                    } else if wasPlayingBeforeScrub {
                        controller.play()
                    }
                }
            )

            HStack(spacing: 4) {
                Text(controller.currentTime.timecodeText)
                    .monospacedDigit()
                Spacer()
                if let loop = controller.loop, loop.isUsable {
                    Text("loop \(loop.duration.shortTimecodeText) · \(controller.completedLoops) run\(controller.completedLoops == 1 ? "" : "s")")
                        .foregroundColor(Palette.mint)
                }
                Spacer()
                Text(controller.duration.shortTimecodeText)
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Palette.secondaryText)

            HStack(spacing: compact ? 10 : 16) {
                transportButton("gobackward.5", label: "Back 5 seconds") {
                    controller.nudge(by: -5)
                }

                if controller.capabilities.contains(.frameStep) {
                    transportButton("backward.frame", label: "Previous frame") {
                        controller.stepFrames(-1)
                    }
                }

                Button {
                    Haptics.tap()
                    controller.togglePlayPause()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .frame(width: 54, height: 44)
                        .background(Capsule().fill(Palette.surfaceRaised))
                        .foregroundColor(Palette.primaryText)
                }
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

                if controller.capabilities.contains(.frameStep) {
                    transportButton("forward.frame", label: "Next frame") {
                        controller.stepFrames(1)
                    }
                }

                transportButton("goforward.5", label: "Forward 5 seconds") {
                    controller.nudge(by: 5)
                }
            }

            HStack(spacing: 8) {
                speedControl
                Spacer(minLength: 8)
                loopControls
            }
        }
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .foregroundColor(Palette.secondaryText)
        }
        .accessibilityLabel(label)
    }

    private var speedControl: some View {
        Menu {
            ForEach(availableSpeeds, id: \.self) { speed in
                Button {
                    Haptics.tap()
                    controller.setRate(speed)
                } label: {
                    if abs(controller.rate - speed) < 0.001 {
                        Label(speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(speed))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                Text(speedLabel(controller.rate))
                    .monospacedDigit()
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(controller.rate == 1.0 ? Palette.secondaryText : Palette.amber)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.surfaceRaised))
        }
    }

    private var loopControls: some View {
        HStack(spacing: 6) {
            loopButton("A", isSet: controller.loop != nil) {
                controller.setLoopStart(controller.currentTime)
            }
            loopButton("B", isSet: controller.loop != nil) {
                controller.setLoopEnd(controller.currentTime)
            }
            if controller.loop != nil {
                Button {
                    Haptics.tap()
                    controller.clearLoop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Palette.surfaceRaised))
                        .foregroundColor(Palette.secondaryText)
                }
                .accessibilityLabel("Clear loop")
            }
        }
    }

    private func loopButton(_ title: String, isSet: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.thud()
            action()
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .frame(width: 36, height: 32)
                .background(Capsule().fill(isSet ? Palette.mint.opacity(0.22) : Palette.surfaceRaised))
                .foregroundColor(isSet ? Palette.mint : Palette.secondaryText)
        }
        .accessibilityLabel(title == "A" ? "Set loop start here" : "Set loop end here")
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == 1.0 ? "1x" : String(format: "%gx", speed)
    }
}
