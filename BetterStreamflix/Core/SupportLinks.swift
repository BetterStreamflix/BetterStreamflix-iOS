import Foundation

/// Central support and community destinations for BetterStreamflix.
enum SupportLinks {
    static let githubRepository = URL(string: "https://github.com/BetterStreamflix/BetterStreamflix-iOS")!
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/betterstreamflix")!
    static let telegram = URL(string: "https://t.me/BetterStreamflix")!
    static let discord = URL(string: "https://discord.gg/R4F72rMUZ8")!
    static let patreon = URL(string: "https://www.patreon.com/BetterStreamflix")!

    /// Public JSON feed used by in-app update checks (no authentication).
    static let iosUpdateFeed = URL(
        string: "https://raw.githubusercontent.com/BetterStreamflix/BetterStreamflix-updates/main/ios/latest.json"
    )!
}
