import SwiftUI

/// The app is used in a dance studio: phone propped against a mirror, arm's length away, often in
/// dim light. That drives every choice here — a dark ground so the screen is not a spotlight,
/// large high-contrast controls, and one saturated accent reserved for the record affordance so it
/// is unmistakable from three metres away.
enum Palette {
    static let ink = Color(red: 0.043, green: 0.043, blue: 0.063)          // page ground
    static let surface = Color(red: 0.086, green: 0.086, blue: 0.122)      // cards
    static let surfaceRaised = Color(red: 0.133, green: 0.133, blue: 0.180)
    static let hairline = Color.white.opacity(0.10)

    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)

    static let accent = Color(red: 1.0, green: 0.31, blue: 0.56)          // hot pink, brand
    static let record = Color(red: 1.0, green: 0.22, blue: 0.35)          // reserved for capture
    static let mint = Color(red: 0.24, green: 0.86, blue: 0.62)
    static let violet = Color(red: 0.55, green: 0.42, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.71, blue: 0.24)

    static func difficultyColor(_ difficulty: Difficulty) -> Color {
        switch difficulty {
        case .rookie, .easy: return mint
        case .moderate: return amber
        case .hard, .killer: return record
        }
    }
}

enum Metric {
    static let corner: CGFloat = 16
    static let cardCorner: CGFloat = 18
    static let gutter: CGFloat = 16
    /// Anything the user taps mid-routine, sweaty and out of breath, gets this.
    static let studioTapTarget: CGFloat = 56
}

extension View {
    func cardSurface(raised: Bool = false) -> some View {
        background(
            RoundedRectangle(cornerRadius: Metric.cardCorner, style: .continuous)
                .fill(raised ? Palette.surfaceRaised : Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metric.cardCorner, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1)
        )
    }

    /// Mirrors a view horizontally. Used for the reference video and the camera alike so a
    /// mirrored practice session is consistent everywhere.
    func mirrored(_ isMirrored: Bool) -> some View {
        scaleEffect(x: isMirrored ? -1 : 1, y: 1, anchor: .center)
    }

    @ViewBuilder
    func hidden(if condition: Bool) -> some View {
        if condition { EmptyView() } else { self }
    }
}

struct PillLabel: View {
    var text: String
    var symbol: String?
    var tint: Color = Palette.secondaryText
    var filled: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(filled ? Palette.ink : tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(filled ? tint : tint.opacity(0.14))
        )
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Palette.primaryText)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Palette.secondaryText)
                }
            }
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.violet)
            }
        }
    }
}

/// Empty states matter a lot here: a brand new install has no takes, no library and possibly no
/// API key, and "nothing here" with no next step is how an app gets deleted on day one.
struct EmptyStateView: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundColor(Palette.tertiaryText)
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(Palette.primaryText)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(Palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Palette.violet))
                        .foregroundColor(.white)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 320)
        .padding(28)
    }
}

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func thud() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// The count-in beat. Haptic rather than audio so it still lands when the phone is across the
    /// room with music playing.
    static func countBeat(isFinal: Bool) {
        UIImpactFeedbackGenerator(style: isFinal ? .heavy : .rigid).impactOccurred()
    }
}
