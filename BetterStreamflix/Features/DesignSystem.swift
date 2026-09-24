import AVKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum DesignTokens {
    enum Spacing {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
        static let xl: CGFloat = 28
        static let screenHorizontal: CGFloat = 20
    }

    enum Radius {
        static let poster: CGFloat = 10
        static let card: CGFloat = 16
        static let sheet: CGFloat = 22
        static let pill: CGFloat = 999
    }

    enum Typography {
        static let brand = Font.system(size: 28, weight: .semibold, design: .rounded)
        static let hero = Font.system(size: 34, weight: .bold)
        static let shelfTitle = Font.title3.weight(.bold)
        static let body = Font.body.weight(.regular)
        static let metadata = Font.caption.weight(.medium)
        static let caption = Font.subheadline.weight(.medium)
        static let micro = Font.caption2.weight(.light)
    }

    enum Motion {
        static let entrance = Animation.easeOut(duration: 0.55)
        static let soft = Animation.easeInOut(duration: 0.28)
        static let press = Animation.easeOut(duration: 0.16)
        static let heroCrossfade = Animation.easeInOut(duration: 0.45)
        static let watchlistBounce = Animation.spring(response: 0.38, dampingFraction: 0.55)
        static let toast = Animation.spring(response: 0.42, dampingFraction: 0.82)
        static let glassMorph = Animation.spring(response: 0.45, dampingFraction: 0.78)
    }

    enum Haptics {
        @MainActor
        static func watchlistAdded() {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        @MainActor
        static func watchlistRemoved() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        @MainActor
        static func primaryAction() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        @MainActor
        static func selection() {
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    enum Elevation {
        static let softGlowRadius: CGFloat = 14
        static let posterShadow = Color.black.opacity(0.35)
    }
}

struct AppScreenBackground: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        environment.theme.backgroundGradient
            .ignoresSafeArea()
    }
}

struct AppSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                AppTheme.surface,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.border, lineWidth: 1)
            }
    }
}

struct AppPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let glow: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(hex: 0x11141C))
            .background {
                LinearGradient(
                    colors: [Color(hex: 0xF7F9FF), Color(hex: 0xCBD3E1)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(0.65), lineWidth: 0.8)
            }
            .shadow(color: glow.opacity(configuration.isPressed ? 0.2 : 0.5), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(isEnabled ? 1 : 0.46)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct AppHeroFade: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.28),
                .init(color: environment.theme.heroTransition.opacity(0.15), location: 0.48),
                .init(color: environment.theme.heroTransition.opacity(0.82), location: 0.76),
                .init(color: environment.theme.heroTransition, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AppHeroPageTransition: View {
    @EnvironmentObject private var environment: AppEnvironment

    var body: some View {
        LinearGradient(
            stops: [
                .init(color: environment.theme.heroTransition, location: 0),
                .init(color: environment.theme.heroTransition.opacity(0.78), location: 0.24),
                .init(color: environment.theme.heroTransition.opacity(0.3), location: 0.62),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// Resolve the iPad hero from the viewport before artwork loads. Narrow windows
// retain the phone-like ratio; larger windows leave room for the next section.
struct HeroHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = HeroArtworkScrollEffect.heroHeight
}

extension EnvironmentValues {
    var heroHeight: CGFloat {
        get { self[HeroHeightKey.self] }
        set { self[HeroHeightKey.self] = newValue }
    }
}

struct HeroViewportModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            GeometryReader { proxy in
                content.environment(
                    \.heroHeight,
                    min(proxy.size.width * (HeroArtworkScrollEffect.heroHeight / 430), proxy.size.height * 0.72, 900)
                )
            }
        } else {
            content
        }
    }
}

struct HeroHeightModifier: ViewModifier {
    @Environment(\.heroHeight) private var height

    func body(content: Content) -> some View {
        content.frame(height: height)
    }
}

struct HeroArtworkBoundaryClip: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.clipped()
        } else {
            content
        }
    }
}

enum MediaArtworkLayout {
    static let shelfPosterWidth: CGFloat = 112
    static let gridSpacing: CGFloat = 12
    static let gridHorizontalPadding: CGFloat = 20
    static let gridColumns = Array(
        repeating: GridItem(.flexible(), spacing: gridSpacing, alignment: .top),
        count: 3
    )
}

extension TrendingTitle {
    var titleTransitionID: String {
        "tmdb:\(kind.rawValue):\(id)"
    }
}

struct TitleTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

final class TitleTransitionSelection: ObservableObject, @unchecked Sendable {
    var titleID: String?
    var sourceID: String?

    func select(titleID: String, sourceID: String) {
        self.titleID = titleID
        self.sourceID = sourceID
    }
}

struct TitleTransitionSelectionKey: EnvironmentKey {
    static let defaultValue: TitleTransitionSelection? = nil
}

extension EnvironmentValues {
    var titleTransitionNamespace: Namespace.ID? {
        get { self[TitleTransitionNamespaceKey.self] }
        set { self[TitleTransitionNamespaceKey.self] = newValue }
    }

    var titleTransitionSelection: TitleTransitionSelection? {
        get { self[TitleTransitionSelectionKey.self] }
        set { self[TitleTransitionSelectionKey.self] = newValue }
    }
}

struct TitleTransitionSourceModifier: ViewModifier {
    @Environment(\.titleTransitionNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var occurrenceID = UUID().uuidString
    let id: String
    let explicitSourceID: String?

    private var sourceID: String {
        explicitSourceID ?? "\(id):occurrence:\(occurrenceID)"
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), !reduceMotion, let namespace {
            content
                .matchedTransitionSource(id: sourceID, in: namespace)
        } else {
            content
        }
    }
}

struct TitleNavigationTransitionModifier: ViewModifier {
    @Environment(\.titleTransitionNamespace) private var namespace
    @Environment(\.titleTransitionSelection) private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *),
           !reduceMotion,
           let namespace,
           selection?.titleID == id,
           let sourceID = selection?.sourceID {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
    }
}

extension View {
    func titleTransitionSource(id: String, sourceID: String? = nil) -> some View {
        modifier(TitleTransitionSourceModifier(id: id, explicitSourceID: sourceID))
    }

    func titleNavigationTransition(id: String) -> some View {
        modifier(TitleNavigationTransitionModifier(id: id))
    }

    func appSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(AppSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Continues the hero's black endpoint below its fixed frame, then reveals
    /// the active theme background without affecting hero layout or interaction.
    func appHeroPageTransition(height: CGFloat = 140) -> some View {
        overlay(alignment: .bottom) {
            AppHeroPageTransition()
                .frame(height: height)
                .offset(y: height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// Press scale for poster/card buttons. Uses `ButtonStyle` so vertical and
    /// horizontal `ScrollView` pans are not stolen by a zero-distance drag gesture.
    func pressablePoster() -> some View {
        buttonStyle(PressablePosterButtonStyle())
    }

    /// Liquid Glass–ready chrome. Soft interactive material that reads as glass on
    /// current SDKs; when building with an iOS 26+ SDK / Xcode that ships
    /// `glassEffect`, swap this helper to the system Liquid Glass APIs.
    func glassEffectWithFallback(in shape: some Shape = .capsule) -> some View {
        self
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.stroke(Color.white.opacity(0.14), lineWidth: 0.8)
            }
    }

    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { message.wrappedValue = nil }
            },
            message: {
                Text(message.wrappedValue ?? "")
            }
        )
    }
}

/// Plain button chrome with a light press scale. Prefer this over attaching a
/// `DragGesture(minimumDistance: 0)` to poster cells — that gesture wins hit-testing
/// against the enclosing scroll views and makes scrolling only work in the gaps.
struct PressablePosterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DesignTokens.Motion.press, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Reads the key window's top safe-area inset for chrome that sits under a
/// full-bleed `.ignoresSafeArea(edges: .top)` hero or page background.
enum ScreenMetrics {
    @MainActor
    static var topSafeAreaInset: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first
        return keyWindow?.safeAreaInsets.top ?? 59
    }
}

/// Soft scrim behind large page titles / Featured chrome so white type stays
/// readable over bright artwork and the status bar.
struct PageTitleTopScrim: View {
    var height: CGFloat = 120

    var body: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.55),
                Color.black.opacity(0.22),
                Color.black.opacity(0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Keeps the interactive pop gesture alive when the system back button is hidden,
/// and restores tab-bar visibility after immersive detail chrome.
struct NavigationChromeStabilizer: UIViewControllerRepresentable {
    var enablesInteractivePop: Bool = true

    func makeUIViewController(context: Context) -> ChromeController {
        ChromeController(enablesInteractivePop: enablesInteractivePop)
    }

    func updateUIViewController(_ uiViewController: ChromeController, context: Context) {
        uiViewController.enablesInteractivePop = enablesInteractivePop
        uiViewController.applyChrome()
    }

    final class ChromeController: UIViewController, UIGestureRecognizerDelegate {
        var enablesInteractivePop: Bool

        init(enablesInteractivePop: Bool) {
            self.enablesInteractivePop = enablesInteractivePop
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyChrome()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            // Leaving an immersive screen should never leave the tab bar stuck hidden
            // on the parent navigation stack.
            if let tabBarController {
                tabBarController.tabBar.isHidden = false
            }
            // Also restore via the navigation controller's toolbar visibility path.
            navigationController?.setToolbarHidden(false, animated: false)
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            tabBarController?.tabBar.isHidden = false
        }

        func applyChrome() {
            guard enablesInteractivePop,
                  let navigationController,
                  let pop = navigationController.interactivePopGestureRecognizer else { return }
            pop.isEnabled = navigationController.viewControllers.count > 1
            pop.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

struct HeroGlassClusterModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(6)
            .background(.ultraThinMaterial.opacity(0.35), in: Capsule())
            .overlay {
                Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.8)
            }
    }
}
