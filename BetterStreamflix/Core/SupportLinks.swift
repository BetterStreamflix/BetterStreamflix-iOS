import Foundation

/// Central support and community destinations for BetterStreamflix.
enum SupportLinks {
    static let githubRepository = URL(string: "https://github.com/BetterStreamflix/BetterStreamflix-iOS")!
    static let githubReleases = URL(string: "https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases")!
    static let githubLatestRelease = URL(string: "https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases/latest")!
    /// Public update feed (no token). CI mirrors the same payload into BetterStreamflix-updates.
    static let publicUpdateFeed = AppUpdateInfo.publicFeedURL
    static let buyMeACoffee = URL(string: "https://buymeacoffee.com/betterstreamflix")!
    static let telegram = URL(string: "https://t.me/BetterStreamflix")!
    static let discord = URL(string: "https://discord.gg/R4F72rMUZ8")!
    static let patreon = URL(string: "https://www.patreon.com/BetterStreamflix")!
}
