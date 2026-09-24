import SwiftUI

enum SupportCTAKind: String, CaseIterable, Identifiable {
    case coffee
    case telegram
    case discord
    case patreon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coffee: "Buy me a coffee"
        case .telegram: "Join Telegram"
        case .discord: "Join Discord"
        case .patreon: "Support on Patreon"
        }
    }

    var subtitle: String {
        switch self {
        case .coffee: "Fuel the next release"
        case .telegram: "News and community chat"
        case .discord: "Hang out with viewers"
        case .patreon: "Unlock deeper support"
        }
    }

    var systemImage: String {
        switch self {
        case .coffee: "cup.and.saucer.fill"
        case .telegram: "paperplane.fill"
        case .discord: "bubble.left.and.bubble.right.fill"
        case .patreon: "heart.fill"
        }
    }

    var url: URL {
        switch self {
        case .coffee: SupportLinks.buyMeACoffee
        case .telegram: SupportLinks.telegram
        case .discord: SupportLinks.discord
        case .patreon: SupportLinks.patreon
        }
    }

    var fill: Color {
        switch self {
        case .coffee: Color(hex: 0xFFDD00)
        case .telegram: Color(hex: 0x2AABEE)
        case .discord: Color(hex: 0x5865F2)
        case .patreon: Color(hex: 0xFF424D)
        }
    }

    var labelColor: Color {
        switch self {
        case .coffee: .black
        case .telegram, .discord, .patreon: .white
        }
    }

    var secondaryLabelColor: Color {
        switch self {
        case .coffee: .black.opacity(0.62)
        case .telegram, .discord, .patreon: .white.opacity(0.78)
        }
    }
}

struct SupportCTAButton: View {
    let kind: SupportCTAKind

    var body: some View {
        Link(destination: kind.url) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(kind == .coffee ? 0.35 : 0.18))
                        .frame(width: 42, height: 42)
                    Image(systemName: kind.systemImage)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(kind.labelColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(kind.labelColor)
                    Text(kind.subtitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(kind.secondaryLabelColor)
                }

                Spacer(minLength: 0)

                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(kind.labelColor.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                kind.fill,
                                kind.fill.opacity(0.82),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(.white.opacity(0.28), lineWidth: 1)
            }
            .shadow(color: kind.fill.opacity(0.34), radius: 14, y: 5)
        }
        .buttonStyle(SupportCTAPressStyle())
        .accessibilityHint("Opens in your browser")
    }
}

private struct SupportCTAPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.94 : 1)
            .animation(DesignTokens.Motion.press, value: configuration.isPressed)
    }
}

struct SupportCTAStack: View {
    var body: some View {
        VStack(spacing: 12) {
            ForEach(SupportCTAKind.allCases) { kind in
                SupportCTAButton(kind: kind)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }
}
