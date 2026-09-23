import SwiftUI

struct TutorialRow: View {
    let video: TutorialVideo
    let isPlaying: Bool
    let isPinned: Bool
    let onPlay: () -> Void
    let onPin: () -> Void
    let onHide: () -> Void

    var body: some View {
        Button(action: {
            Haptics.tap()
            onPlay()
        }) {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 5) {
                    Text(video.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(isPlaying ? Palette.mint : Palette.primaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(video.channelTitle)
                            .lineLimit(1)
                        if video.viewCount > 0 {
                            Text("·")
                            Text(video.viewCountText)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Palette.secondaryText)

                    if !video.badges.isEmpty {
                        badgeRow
                    }

                    if !video.isEmbeddable {
                        Text("Plays on YouTube only")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Palette.amber)
                    }
                }
                Spacer(minLength: 0)
                Button(action: {
                    onPin()
                }) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundColor(isPinned ? Palette.accent : Palette.tertiaryText)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPinned ? "Unpin tutorial" : "Pin tutorial")
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isPlaying ? Palette.mint.opacity(0.10) : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isPlaying ? Palette.mint.opacity(0.4) : Palette.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onPin()
            } label: {
                Label(isPinned ? "Unpin" : "Pin to top", systemImage: isPinned ? "pin.slash" : "pin")
            }
            if let url = video.watchURL {
                Button {
                    UIApplication.shared.open(url)
                } label: {
                    Label("Open in YouTube", systemImage: "arrow.up.forward.square")
                }
                ShareLink(item: url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive) {
                onHide()
            } label: {
                Label("Not useful — hide", systemImage: "eye.slash")
            }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: video.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(Palette.surfaceRaised)
                        .overlay(
                            Image(systemName: "play.rectangle")
                                .foregroundColor(Palette.tertiaryText)
                        )
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if video.durationSeconds > 0 {
                Text(video.durationText)
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.75)))
                    .padding(4)
            }

            if isPlaying {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Palette.mint, lineWidth: 2)
                    .frame(width: 112, height: 63)
            }
        }
    }

    private var badgeRow: some View {
        HStack(spacing: 4) {
            ForEach(video.badges.prefix(3)) { badge in
                PillLabel(
                    text: badge.label,
                    symbol: badge.symbol,
                    tint: badge == .mirrored ? Palette.mint : Palette.tertiaryText
                )
            }
        }
    }
}
