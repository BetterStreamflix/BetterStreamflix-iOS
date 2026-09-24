import SwiftUI

struct SplashScreen: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isBreathing = false

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.5"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String
        if let build, !build.isEmpty {
            return "v\(version) (\(build))"
        }
        return "v\(version)"
    }

    var body: some View {
        ZStack {
            // Full-bleed graphite matching launch screen — no side letterboxing.
            Color(hex: 0x080A0C)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color(hex: 0x05070C),
                    environment.theme.backgroundSecondary.opacity(0.85),
                    Color(hex: 0x080A0C)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    environment.theme.accent.opacity(0.22),
                    environment.theme.glow.opacity(0.1),
                    .clear
                ],
                center: .center,
                startRadius: 24,
                endRadius: 260
            )
            .scaleEffect(isBreathing ? 1.06 : 0.94)
            .opacity(isVisible ? 1 : 0)
            .blur(radius: reduceMotion ? 0 : 10)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Image("SplashMark")
                .resizable()
                .scaledToFill()
                .frame(width: 168, height: 168)
                .clipShape(RoundedRectangle(cornerRadius: 38, style: .continuous))
                .shadow(color: environment.theme.glow.opacity(0.5), radius: 28, y: 10)
                .scaleEffect(isVisible ? (isBreathing && !reduceMotion ? 1.02 : 1) : 0.88)
                .opacity(isVisible ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 2.0).repeatForever(autoreverses: true),
                    value: isBreathing
                )
                .accessibilityHidden(true)

            VStack {
                Spacer()
                ProgressView()
                    .tint(environment.theme.accentBright)
                    .controlSize(.small)
                    .opacity(isVisible ? 0.85 : 0)
                    .padding(.bottom, 10)
                    .accessibilityLabel("Loading")
                Text(versionText)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(AppTheme.primaryText.opacity(0.34))
                    .padding(.bottom, 20)
            }
            .opacity(isVisible ? 1 : 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading BetterStreamflix")
        .onAppear {
            withAnimation(reduceMotion ? nil : DesignTokens.Motion.entrance) {
                isVisible = true
            }
            isBreathing = true
        }
    }
}
