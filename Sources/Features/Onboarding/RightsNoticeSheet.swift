import SwiftUI

/// First-launch explainer. Two pages: what each kind of video can do, and why. The asymmetry is
/// the thing a new user trips over, so it is said once, plainly, before they find it by accident.
struct RightsNoticeSheet: View {
    @EnvironmentObject private var store: AppStore
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                twoSourcesPage.tag(0)
                yourFilesPage.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))

            Button {
                if page == 0 {
                    withAnimation { page = 1 }
                } else {
                    Haptics.success()
                    store.settings.hasAcceptedRightsNotice = true
                }
            } label: {
                Text(page == 0 ? "Next" : "Got it — let's dance")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(RoundedRectangle(cornerRadius: Metric.corner).fill(Palette.accent))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Palette.ink.ignoresSafeArea())
    }

    private var twoSourcesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Two kinds of video")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(Palette.primaryText)
                Text("Practice Room works with official YouTube videos and with files you own. They can do different things, and that's on purpose.")
                    .font(.system(size: 14))
                    .foregroundColor(Palette.secondaryText)

                sourceCard(
                    title: "YouTube videos",
                    symbol: "play.rectangle",
                    tint: Palette.violet,
                    can: ["Slow down to 0.25x", "Loop any part A→B", "Save named sections", "Ranked tutorial lists"],
                    cannot: ["Mirror", "Record yourself over it", "Export with the music"]
                )
                sourceCard(
                    title: "Your own files",
                    symbol: "film.stack",
                    tint: Palette.mint,
                    can: ["Everything above", "Mirror", "Frame-by-frame", "Record takes side by side or as a ghost overlay", "Export takes with the music"],
                    cannot: []
                )
            }
            .padding(24)
        }
    }

    private var yourFilesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Why the difference?")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(Palette.primaryText)
                Text("YouTube videos play in YouTube's own player, under YouTube's terms. Those terms allow changing speed and seeking, but not flipping the picture, drawing over it or recording its audio. So the app doesn't.")
                    .font(.system(size: 14))
                    .foregroundColor(Palette.secondaryText)
                Text("Videos you filmed, bought, got from your teacher, or that are openly licensed are yours to work with — so every tool is unlocked for them.")
                    .font(.system(size: 14))
                    .foregroundColor(Palette.secondaryText)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(MediaProvenance.allCases) { provenance in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(Palette.mint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provenance.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Palette.primaryText)
                                Text(provenance.detail)
                                    .font(.system(size: 12))
                                    .foregroundColor(Palette.tertiaryText)
                            }
                        }
                    }
                }
                .padding(14)
                .cardSurface()

                Text("When you import a file you'll be asked which of these it is. Please only import videos you have the right to use.")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.tertiaryText)
            }
            .padding(24)
        }
    }

    private func sourceCard(title: String, symbol: String, tint: Color,
                            can: [String], cannot: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundColor(tint)
            ForEach(can, id: \.self) { line in
                Label(line, systemImage: "checkmark")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.primaryText)
            }
            ForEach(cannot, id: \.self) { line in
                Label(line, systemImage: "xmark")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.tertiaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface()
    }
}
