import SwiftUI
import UIKit

/// Paste a YouTube link, then decide what it is: the main reference or one more tutorial.
struct PasteLinkSheet: View {
    @ObservedObject var model: ChoreographyDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isWorking = false

    private var detectedID: String? { YouTubeLink.videoID(from: text) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste a YouTube link")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Palette.primaryText)
                Text("Any youtube.com, youtu.be or Shorts link works. It plays in YouTube's own player.")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.secondaryText)

                HStack(spacing: 8) {
                    TextField("https://youtu.be/…", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceRaised))
                        .foregroundColor(Palette.primaryText)
                    Button {
                        if let pasted = UIPasteboard.general.string { text = pasted }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.surfaceRaised))
                    }
                    .accessibilityLabel("Paste from clipboard")
                }

                if !text.isEmpty {
                    Label(detectedID == nil ? "Not a YouTube link" : "Video \(detectedID!)",
                          systemImage: detectedID == nil ? "xmark.circle" : "checkmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(detectedID == nil ? Palette.amber : Palette.mint)
                }

                VStack(spacing: 10) {
                    Button {
                        model.setReference(fromPastedURL: text)
                    } label: {
                        sheetButtonLabel("Use as the reference video", symbol: "figure.dance", tint: Palette.accent)
                    }
                    Button {
                        isWorking = true
                        Task {
                            await model.addPastedVideo(text)
                            isWorking = false
                        }
                    } label: {
                        sheetButtonLabel("Add as a tutorial", symbol: "graduationcap", tint: Palette.violet)
                    }
                }
                .disabled(detectedID == nil || isWorking)
                .opacity(detectedID == nil ? 0.5 : 1)

                if isWorking {
                    ProgressView().tint(Palette.secondaryText)
                        .frame(maxWidth: .infinity)
                }
                Spacer()
            }
            .padding(Metric.gutter)
            .background(Palette.ink.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sheetButtonLabel(_ title: String, symbol: String, tint: Color) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12).fill(tint))
            .foregroundColor(.white)
    }
}

/// Explains why a control does nothing on the YouTube source, and what does work instead.
struct UnsupportedCapabilitySheet: View {
    let capability: PlaybackCapabilities
    let choreography: Choreography
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(size: 34, weight: .light))
                        .foregroundColor(Palette.amber)
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(Palette.primaryText)
                    Text(reason)
                        .font(.system(size: 14))
                        .foregroundColor(Palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("What works instead")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(Palette.primaryText)
                        .padding(.top, 6)

                    ForEach(alternatives, id: \.self) { line in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "arrow.turn.down.right")
                                .foregroundColor(Palette.mint)
                            Text(line)
                                .font(.system(size: 13))
                                .foregroundColor(Palette.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if capability == .mirror,
                       let url = YouTubeLink.searchURL(for: choreography.tutorialSearch.query + " mirrored") {
                        Button {
                            UIApplication.shared.open(url)
                        } label: {
                            Label("Search YouTube for mirrored versions", systemImage: "magnifyingglass")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                }
                .padding(Metric.gutter)
            }
            .background(Palette.ink.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var symbol: String {
        switch capability {
        case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .cameraOverlay: return "record.circle"
        default: return "lock"
        }
    }

    private var title: String {
        switch capability {
        case .mirror: return "Mirroring needs your own file"
        case .cameraOverlay: return "Recording needs your own file"
        case .frameStep: return "Frame stepping needs your own file"
        case .audioCapture: return "Audio export needs your own file"
        default: return "Not available on YouTube videos"
        }
    }

    private var reason: String {
        "This video plays inside YouTube's official player. Its terms let apps change speed and jump around, but not flip the picture, draw a camera over it or capture its sound — so Practice Room doesn't."
    }

    private var alternatives: [String] {
        var lines: [String] = []
        if capability == .mirror {
            lines.append("Filter the tutorial list below by “Mirrored” — many teachers upload a flipped version.")
        }
        lines.append("Import a video you own (your class recording, a paid pack, a file from your teacher) in the Library tab and link it to “\(choreography.title)”.")
        lines.append("Once it's linked, Studio unlocks here: mirror, frame steps, side-by-side and ghost recording, and export with music.")
        return lines
    }
}
