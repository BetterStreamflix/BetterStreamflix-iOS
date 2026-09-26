import Foundation

/// Shared subtitle-provider enablement so Settings, player discovery, and cache stay aligned.
enum SubtitleProviderPreferences {
    static let subDLKey = "subtitle.provider.subdl.enabled"
    static let openSubtitlesKey = "subtitle.provider.opensubtitles.enabled"
    static let wizdomKey = "subtitle.provider.wizdom.enabled"
    static let ktuvitKey = "subtitle.provider.ktuvit.enabled"
    static let externalStreamsKey = "subtitle.provider.externalStreams.enabled"

    /// Third-party content providers that can inject external subtitle tracks.
    static let contentProviderIDs: Set<String> = [
        "subdl",
        "opensubtitles",
        "wizdom",
        "ktuvit",
        "external-stream-subtitles",
    ]

    static let totalProviderCount = 5

    static func isEnabled(_ key: String, defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    static func enabledIDs(defaults: UserDefaults = .standard) -> Set<String> {
        var ids = Set<String>()
        if isEnabled(subDLKey, defaults: defaults) { ids.insert("subdl") }
        if isEnabled(openSubtitlesKey, defaults: defaults) { ids.insert("opensubtitles") }
        if isEnabled(wizdomKey, defaults: defaults) { ids.insert("wizdom") }
        if isEnabled(ktuvitKey, defaults: defaults) { ids.insert("ktuvit") }
        if isEnabled(externalStreamsKey, defaults: defaults) {
            ids.insert("external-stream-subtitles")
        }
        return ids
    }

    static func summary(enabledCount: Int) -> String {
        switch enabledCount {
        case 0: return "None"
        case totalProviderCount: return "All"
        case 1: return "1 selected"
        default: return "\(enabledCount) selected"
        }
    }
}
