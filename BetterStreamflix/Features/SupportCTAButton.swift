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
}

struct SupportCTAButton: View {
    let kind: SupportCTAKind

    var body: some View {
        Link(destination: kind.url) {
            Label(kind.title, systemImage: kind.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(kind.labelColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(kind.fill, in: Capsule())
                .shadow(color: kind.fill.opacity(0.35), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens in your browser")
    }
}

struct SupportCTAStack: View {
    var body: some View {
        VStack(spacing: 10) {
            ForEach(SupportCTAKind.allCases) { kind in
                SupportCTAButton(kind: kind)
            }
        }
    }
}
