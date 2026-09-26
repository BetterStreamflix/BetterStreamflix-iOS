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

    /// Prefer SDH / hearing-impaired tracks when the user opts in.
    static var prefersHearingImpaired: Bool {
        get { UserDefaults.standard.bool(forKey: "player.subtitle.preferHearingImpaired") }
        set { UserDefaults.standard.set(newValue, forKey: "player.subtitle.preferHearingImpaired") }
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

    /// Heuristic quality: preferred language → release/score cues → SDH preference → provider.
    static func qualityScore(
        for subtitle: SubtitleSource,
        primary: String?,
        secondary: String?,
        releaseHint: String? = nil,
        prefersHI: Bool = prefersHearingImpaired
    ) -> Int {
        var score = 0
        let group = languageGroup(for: subtitle, primary: primary, secondary: secondary)
        score += (4 - min(group, 4)) * 1_000

        let haystack = "\(subtitle.label) \(subtitle.providerName)".lowercased()
        let isHI = haystack.contains("sdh")
            || haystack.contains("hearing")
            || haystack.contains("hi]")
            || haystack.contains("[hi")
            || haystack.contains("cc)")
        if prefersHI {
            if isHI { score += 180 } else { score -= 20 }
        } else if isHI {
            score -= 40
        }

        if haystack.contains("forced") { score -= 120 }

        if let hint = releaseHint?.lowercased(), !hint.isEmpty {
            let tokens = hint
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
            let matches = tokens.filter { haystack.contains($0) }.count
            score += min(matches, 6) * 25
        }

        // Prefer labeled release names over bare language-only rows.
        if subtitle.label.contains("·") || subtitle.label.contains(" - ") {
            score += 30
        }

        // Soft bump for popular catalogs that usually ship cleaner timing.
        switch subtitle.providerID {
        case "opensubtitles": score += 15
        case "subdl": score += 12
        case "native-hls", "stream": score += 40
        default: break
        }

        return score
    }

    static func compare(
        _ left: SubtitleSource,
        _ right: SubtitleSource,
        primary: String?,
        secondary: String?,
        releaseHint: String? = nil
    ) -> Bool {
        let leftScore = qualityScore(
            for: left, primary: primary, secondary: secondary, releaseHint: releaseHint
        )
        let rightScore = qualityScore(
            for: right, primary: primary, secondary: secondary, releaseHint: releaseHint
        )
        if leftScore != rightScore { return leftScore > rightScore }

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
        releaseHint: String? = nil,
        defaults: UserDefaults = .standard
    ) -> [SubtitleSource] {
        let prefs = preferredLanguageCodes(defaults: defaults)
        let primaryCode = primary ?? prefs.primary
        let secondaryCode = secondary ?? prefs.secondary
        return sources.sorted {
            compare($0, $1, primary: primaryCode, secondary: secondaryCode, releaseHint: releaseHint)
        }
    }

    static func isHearingImpaired(_ subtitle: SubtitleSource) -> Bool {
        let haystack = subtitle.label.lowercased()
        return haystack.contains("sdh")
            || haystack.contains("hearing")
            || haystack.contains("[hi")
            || haystack.contains("hi]")
    }

    static func isForced(_ subtitle: SubtitleSource) -> Bool {
        subtitle.label.lowercased().contains("forced")
    }
}
