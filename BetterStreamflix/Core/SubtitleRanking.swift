import Foundation

/// Shared language-aware ranking so discovery lists match auto-select / injection order.
enum SubtitleRanking {
    static func preferredLanguageCodes(
        defaults: UserDefaults = .standard
    ) -> (primary: String?, secondary: String?) {
        (
            SubtitleLanguage.canonicalCode(
                defaults.string(forKey: "player.subtitleLanguage.primary")
            ),
            SubtitleLanguage.canonicalCode(
                defaults.string(forKey: "player.subtitleLanguage.secondary")
            )
        )
    }

    static func languageGroup(
        for subtitle: SubtitleSource,
        primary: String?,
        secondary: String?
    ) -> Int {
        let code = subtitle.canonicalLanguageCode
        if let primary, code == primary { return 0 }
        if let secondary, !secondary.isEmpty, code == secondary { return 1 }
        if subtitle.providerID == "native-hls" || subtitle.providerID == "stream" { return 2 }
        if subtitle.isDefault { return 3 }
        return 4
    }

    static func compare(
        _ left: SubtitleSource,
        _ right: SubtitleSource,
        primary: String?,
        secondary: String?
    ) -> Bool {
        let leftGroup = languageGroup(for: left, primary: primary, secondary: secondary)
        let rightGroup = languageGroup(for: right, primary: primary, secondary: secondary)
        if leftGroup != rightGroup { return leftGroup < rightGroup }

        let leftLang = SubtitleLanguage.displayName(left.languageCode)
        let rightLang = SubtitleLanguage.displayName(right.languageCode)
        let langCompare = leftLang.localizedCaseInsensitiveCompare(rightLang)
        if langCompare != .orderedSame { return langCompare == .orderedAscending }

        let leftBuiltIn = left.providerID == "native-hls" || left.providerID == "stream"
        let rightBuiltIn = right.providerID == "native-hls" || right.providerID == "stream"
        if leftBuiltIn != rightBuiltIn { return leftBuiltIn && !rightBuiltIn }

        let providerCompare = left.providerName.localizedCaseInsensitiveCompare(right.providerName)
        if providerCompare != .orderedSame { return providerCompare == .orderedAscending }

        return left.label.localizedCaseInsensitiveCompare(right.label) == .orderedAscending
    }

    static func sort(
        _ sources: [SubtitleSource],
        primary: String? = nil,
        secondary: String? = nil,
        defaults: UserDefaults = .standard
    ) -> [SubtitleSource] {
        let prefs = preferredLanguageCodes(defaults: defaults)
        let primaryCode = primary ?? prefs.primary
        let secondaryCode = secondary ?? prefs.secondary
        return sources.sorted {
            compare($0, $1, primary: primaryCode, secondary: secondaryCode)
        }
    }
}
