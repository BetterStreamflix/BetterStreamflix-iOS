import AppIntents
import Foundation

/// Bridges Siri / Shortcuts into in-app Stremio navigation.
enum StremioShortcutBridge {
    static let didReceiveNotification = Notification.Name("stremio.shortcut.didReceive")
    static let routeKey = "stremio.shortcut.route.v1"

    enum Route: String {
        case hub
        case debrid
        case addons
        case resume
    }

    static func post(_ route: Route) {
        UserDefaults.standard.set(route.rawValue, forKey: routeKey)
        NotificationCenter.default.post(name: didReceiveNotification, object: route.rawValue)
    }

    static func consumePending() -> Route? {
        guard let raw = UserDefaults.standard.string(forKey: routeKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: routeKey)
        return Route(rawValue: raw)
    }
}

struct OpenStremioHubIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Stremio Hub"
    static var description = IntentDescription("Browse Stremio catalogs in BetterStreamflix.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { StremioShortcutBridge.post(.hub) }
        return .result()
    }
}

struct OpenDebridSettingsIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Debrid Settings"
    static var description = IntentDescription("Manage Real-Debrid and other Debrid tokens.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { StremioShortcutBridge.post(.debrid) }
        return .result()
    }
}

struct OpenStremioAddonsIntent: AppIntent {
    static var title: LocalizedStringResource = "Manage Stremio Plugins"
    static var description = IntentDescription("Open the Stremio addon manager.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { StremioShortcutBridge.post(.addons) }
        return .result()
    }
}

struct ResumeContinueWatchingIntent: AppIntent {
    static var title: LocalizedStringResource = "Resume Watching"
    static var description = IntentDescription("Resume the latest Continue Watching title.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run { StremioShortcutBridge.post(.resume) }
        return .result()
    }
}

struct BetterStreamflixShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: OpenStremioHubIntent(),
                phrases: [
                    "Open Stremio in \(.applicationName)",
                    "Browse Stremio with \(.applicationName)",
                ],
                shortTitle: "Stremio Hub",
                systemImageName: "sparkles.tv"
            ),
            AppShortcut(
                intent: OpenDebridSettingsIntent(),
                phrases: [
                    "Open Debrid in \(.applicationName)",
                    "Manage Debrid in \(.applicationName)",
                ],
                shortTitle: "Debrid",
                systemImageName: "key.horizontal"
            ),
            AppShortcut(
                intent: OpenStremioAddonsIntent(),
                phrases: [
                    "Manage Stremio plugins in \(.applicationName)",
                ],
                shortTitle: "Plugins",
                systemImageName: "puzzlepiece.extension"
            ),
            AppShortcut(
                intent: ResumeContinueWatchingIntent(),
                phrases: [
                    "Resume in \(.applicationName)",
                    "Continue watching in \(.applicationName)",
                ],
                shortTitle: "Resume",
                systemImageName: "play.fill"
            ),
        ]
    }
}
