import SwiftUI

struct SplashScreen: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isBreathing = false

    private var versionText: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.1"
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
            LinearGradient(
                colors: [
                    Color(hex: 0x05070C),
                    environment.theme.backgroundSecondary,
                    Color(hex: 0x080A10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [
                    environment.theme.accent.opacity(0.28),
                    environment.theme.glow.opacity(0.12),
                    .clear
                ],
                center: .center,
                startRadius: 20,
                endRadius: 220
            )
            .frame(width: 420, height: 420)
            .scaleEffect(isBreathing ? 1.05 : 0.94)
            .opacity(isVisible ? 1 : 0)
            .blur(radius: reduceMotion ? 0 : 8)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            VStack(spacing: DesignTokens.Spacing.lg) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 148, height: 148)
                    .shadow(color: environment.theme.glow.opacity(0.55), radius: 28, y: 8)
                    .scaleEffect(isVisible ? 1 : 0.88)
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("BetterStreamflix")
                        .font(DesignTokens.Typography.brand)
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.primaryText)

                    Text("Cinematic streaming")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(AppTheme.primaryText.opacity(0.55))
                }
                .opacity(isVisible ? 1 : 0)

                ProgressView()
                    .tint(environment.theme.accentBright)
                    .controlSize(.small)
                    .padding(.top, 6)
                    .opacity(isVisible ? 1 : 0)
                    .accessibilityLabel("Loading")
            }
            .scaleEffect(isVisible ? (isBreathing && !reduceMotion ? 1.012 : 1) : 0.94)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 2.1).repeatForever(autoreverses: true),
                value: isBreathing
            )

            VStack {
                Spacer()
                Text(versionText)
                    .font(DesignTokens.Typography.micro)
                    .foregroundStyle(AppTheme.primaryText.opacity(0.38))
                    .padding(.bottom, 18)
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
