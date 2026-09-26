import Foundation

/// Language grouping for BetterStreamflix playback sources, matching Android's provider browser.
enum ProviderLanguageGroup: String, CaseIterable, Identifiable, Codable {
    case german
    case english
    case italian
    case spanish
    case french
    case polish
    case core

    var id: String { rawValue }

    /// Spoken playback languages the user can pick (excludes `.core`).
    static var spokenLanguages: [ProviderLanguageGroup] {
        [.german, .english, .italian, .spanish, .french, .polish]
    }

    var isSpokenLanguage: Bool { self != .core }

    /// Primary ISO 639-1 code used for discovery ranking inside this group.
    var primaryAudioCode: String {
        switch self {
        case .german: "de"
        case .english: "en"
        case .italian: "it"
        case .spanish: "es"
        case .french: "fr"
        case .polish: "pl"
        case .core: "en"
        }
    }

    var flagEmoji: String {
        switch self {
        case .german: "🇩🇪"
        case .english: "🇬🇧"
        case .italian: "🇮🇹"
        case .spanish: "🇪🇸"
        case .french: "🇫🇷"
        case .polish: "🇵🇱"
        case .core: "🎬"
        }
    }

    var title: String {
        switch self {
        case .german: "German"
        case .english: "English"
        case .italian: "Italian"
        case .spanish: "Spanish"
        case .french: "French"
        case .polish: "Polish"
        case .core: "Core"
        }
    }

    var providerCount: Int {
        PlaybackSourcePreferenceID.sources(in: self).count
    }

    var confirmationMessage: String {
        "\(title) sources active · \(providerCount) providers"
    }
}

/// Full BetterStreamflix VOD playback source inventory (Android `Provider.providers` minus live/IPTV/platform).
enum PlaybackSourcePreferenceID: String, CaseIterable, Identifiable {
    // Core (already on iOS before 0.1.0)
    case streamingCommunity
    case hiAnime
    case anikoto
    case animeIL
    case stremio
    case bundledHTTP

    // German
    case serienstream
    case aniworld
    case filmpalast
    case filmo
    case hdfilme
    case kinoger
    case megakino
    case einschalten
    case moflixStream

    // English
    case sflix
    case ridomovies
    case anymovie
    case mkissa

    // Italian
    case altadefinizione01
    case guardaflix
    case cb01
    case animeunity
    case animesaturn
    case guardaserie
    case streamingita
    case animeworld

    // Spanish
    case fanpelis
    case cinecalidad
    case flixlatam
    case seriesflix
    case seriesturcas
    case lacartoons
    case animefenix
    case animeflv
    case jkanime
    case tioanime
    case animeav1
    case cuevanaeu
    case latanime
    case doramasflix
    case animeonlineninja
    case sololatino
    case cine24h
    case pelisplusto
    case pelisflixhd
    case poseidonhd2
    case cinehax

    // French
    case wiflix
    case frenchanime
    case frenchstream
    case frembed
    case kidraz
    case frenchmanga
    case unjourunfilm
    case afterdark

    // Polish
    case filmyonlinecc
    case zaluknij

    var id: String { rawValue }

    var languageGroup: ProviderLanguageGroup {
        switch self {
        case .streamingCommunity, .hiAnime, .anikoto, .animeIL, .stremio, .bundledHTTP:
            return .core
        case .serienstream, .aniworld, .filmpalast, .filmo, .hdfilme,
             .kinoger, .megakino, .einschalten, .moflixStream:
            return .german
        case .sflix, .ridomovies, .anymovie, .mkissa:
            return .english
        case .altadefinizione01, .guardaflix, .cb01, .animeunity, .animesaturn,
             .guardaserie, .streamingita, .animeworld:
            return .italian
        case .fanpelis, .cinecalidad, .flixlatam, .seriesflix, .seriesturcas,
             .lacartoons, .animefenix, .animeflv, .jkanime, .tioanime, .animeav1,
             .cuevanaeu, .latanime, .doramasflix, .animeonlineninja, .sololatino,
             .cine24h, .pelisplusto, .pelisflixhd, .poseidonhd2, .cinehax:
            return .spanish
        case .wiflix, .frenchanime, .frenchstream, .frembed, .kidraz,
             .frenchmanga, .unjourunfilm, .afterdark:
            return .french
        case .filmyonlinecc, .zaluknij:
            return .polish
        }
    }

    var title: String {
        switch self {
        case .streamingCommunity: "StreamingCommunity"
        case .hiAnime: "HiAnime"
        case .anikoto: "Anikoto"
        case .animeIL: "AnimeIL"
        case .stremio: "Stremio Addons"
        case .bundledHTTP: "Built-in HTTP"
        case .serienstream: "SerienStream"
        case .aniworld: "AniWorld"
        case .filmpalast: "FilmPalast"
        case .filmo: "Filmo"
        case .hdfilme: "HDFilme"
        case .kinoger: "KinoGer"
        case .megakino: "MEGAKino"
        case .einschalten: "Einschalten"
        case .moflixStream: "Moflix-stream"
        case .sflix: "SFlix"
        case .ridomovies: "Ridomovies"
        case .anymovie: "AnyMovie"
        case .mkissa: "MKissa"
        case .altadefinizione01: "Altadefinizione01"
        case .guardaflix: "GuardaFlix"
        case .cb01: "CB01"
        case .animeunity: "AnimeUnity"
        case .animesaturn: "AnimeSaturn"
        case .guardaserie: "GuardaSerie"
        case .streamingita: "StreamingIta"
        case .animeworld: "AnimeWorld"
        case .fanpelis: "Fanpelis"
        case .cinecalidad: "CineCalidad"
        case .flixlatam: "FlixLatam"
        case .seriesflix: "SeriesFlix"
        case .seriesturcas: "Series Turcas"
        case .lacartoons: "La Cartoons"
        case .animefenix: "Animefenix"
        case .animeflv: "AnimeFLV"
        case .jkanime: "JKAnime"
        case .tioanime: "TioAnime"
        case .animeav1: "AnimeAV1"
        case .cuevanaeu: "Cuevana 3"
        case .latanime: "Latanime"
        case .doramasflix: "Doramasflix"
        case .animeonlineninja: "Anime Online Ninja"
        case .sololatino: "SoloLatino"
        case .cine24h: "Cine24h"
        case .pelisplusto: "Pelisplusto"
        case .pelisflixhd: "PelisflixHD"
        case .poseidonhd2: "PoseidonHD2"
        case .cinehax: "CineHax"
        case .wiflix: "Wiflix"
        case .frenchanime: "FrenchAnime"
        case .frenchstream: "FrenchStream"
        case .frembed: "Frembed"
        case .kidraz: "Kidraz"
        case .frenchmanga: "FrenchManga"
        case .unjourunfilm: "1Jour1Film"
        case .afterdark: "AfterDark"
        case .filmyonlinecc: "FilmyOnline"
        case .zaluknij: "Zaluknij"
        }
    }

    var subtitle: String {
        switch languageGroup {
        case .german: "German audio streams"
        case .english: "English streams"
        case .italian: "Italian streams"
        case .spanish: "Spanish / LatAm streams"
        case .french: "French streams"
        case .polish: "Polish streams"
        case .core:
            switch self {
            case .streamingCommunity: "Primary stream resolver for most titles"
            case .hiAnime: "Anime playback (English / Japanese)"
            case .anikoto: "Alternate anime resolver"
            case .animeIL: "Hebrew anime streams"
            case .stremio: "Installed community Stremio addons"
            case .bundledHTTP: "App-bundled direct streams (not a Stremio plugin)"
            default: "Core playback source"
            }
        }
    }

    var defaultsKey: String { "playback.provider.\(rawValue).enabled" }

    /// Every playback source is enabled by default — no language is privileged.
    var defaultEnabled: Bool { true }

    /// Exact provider `id` values used by `PlaybackProvider` implementations.
    var registryMatchIDs: [String] {
        switch self {
        case .streamingCommunity: ["streamingcommunity"]
        case .hiAnime: ["hianime"]
        case .anikoto: ["anikoto"]
        case .animeIL: ["animeil"]
        case .stremio: ["external-streams", "stremio"]
        case .bundledHTTP: ["bundled-http-streams"]
        case .moflixStream: ["moflix-stream"]
        default: [rawValue.lowercased()]
        }
    }

    func matches(providerID: String) -> Bool {
        let lowered = providerID.lowercased()
        return registryMatchIDs.contains { lowered == $0 || lowered.hasPrefix($0) }
    }

    static func sources(in group: ProviderLanguageGroup) -> [PlaybackSourcePreferenceID] {
        allCases.filter { $0.languageGroup == group }
    }
}

enum AppSetupStore {
    static let completedKey = "setup.completed"
    static let catalogSourceKey = "catalog.source"
    static let equalProvidersMigrationKey = "playback.providers.equalLanguages.v1"
    static let languageGroupKey = "playback.languageGroup"
    static let coreResolversKey = "playback.coreResolvers.enabled"
    static let stremioIndependentKey = "playback.stremio.independent"
    static let languageGroupMigrationKey = "playback.languageGroup.v1"
    static let languageDidChangeNotification = Notification.Name("playback.languageGroup.didChange")

    /// Stremio stream discovery can run without enabling every Core anime resolver.
    static var isStremioPlaybackEnabled: Bool {
        if UserDefaults.standard.object(forKey: StremioAddonStore.playbackEnabledKey) != nil {
            return UserDefaults.standard.bool(forKey: StremioAddonStore.playbackEnabledKey)
        }
        return isCoreResolversEnabled && isPlaybackSourceEnabled(.stremio)
    }

    static func setStremioPlaybackEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: StremioAddonStore.playbackEnabledKey)
        setPlaybackSource(.stremio, enabled: enabled)
        if enabled {
            UserDefaults.standard.set(true, forKey: stremioIndependentKey)
        }
        NotificationCenter.default.post(
            name: languageDidChangeNotification,
            object: activePlaybackLanguageGroup.rawValue
        )
    }

    /// One-shot: enable every playback source after removing the German-only default bias.
    static func migrateEqualProvidersIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: equalProvidersMigrationKey) else { return }
        for source in PlaybackSourcePreferenceID.allCases {
            UserDefaults.standard.set(true, forKey: source.defaultsKey)
        }
        UserDefaults.standard.set(true, forKey: equalProvidersMigrationKey)
    }

    /// One-shot: pick German as the active playback language and turn Core off by default.
    static func migratePlaybackLanguageIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: languageGroupMigrationKey) else { return }
        applyLanguageGroup(.german, coreEnabled: false)
        UserDefaults.standard.set(true, forKey: languageGroupMigrationKey)
    }

    static var isCompleted: Bool {
        get {
            if UserDefaults.standard.object(forKey: completedKey) != nil {
                return UserDefaults.standard.bool(forKey: completedKey)
            }
            let looksLikeReturningUser =
                UserDefaults.standard.object(forKey: "appearance.themeColor") != nil
                || UserDefaults.standard.object(forKey: "provider.streamingcommunity.domain") != nil
                || UserDefaults.standard.object(forKey: "player.autoNext") != nil
            if looksLikeReturningUser {
                UserDefaults.standard.set(true, forKey: completedKey)
                return true
            }
            return false
        }
        set { UserDefaults.standard.set(newValue, forKey: completedKey) }
    }

    static var catalogSource: CatalogSourcePreference {
        get {
            CatalogSourcePreference(
                rawValue: UserDefaults.standard.string(forKey: catalogSourceKey) ?? ""
            ) ?? .tmdb
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: catalogSourceKey) }
    }

    /// Active spoken language for playback discovery (never `.core`).
    static var activePlaybackLanguageGroup: ProviderLanguageGroup {
        let raw = UserDefaults.standard.string(forKey: languageGroupKey) ?? ProviderLanguageGroup.german.rawValue
        let group = ProviderLanguageGroup(rawValue: raw) ?? .german
        return group.isSpokenLanguage ? group : .german
    }

    static var isCoreResolversEnabled: Bool {
        if UserDefaults.standard.object(forKey: coreResolversKey) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: coreResolversKey)
    }

    static func setActivePlaybackLanguageGroup(_ group: ProviderLanguageGroup) {
        let selected = group.isSpokenLanguage ? group : .german
        applyLanguageGroup(selected, coreEnabled: isCoreResolversEnabled)
        NotificationCenter.default.post(name: languageDidChangeNotification, object: selected.rawValue)
    }

    static func setCoreResolversEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: coreResolversKey)
        for source in PlaybackSourcePreferenceID.sources(in: .core) {
            // Preserve an independently enabled Stremio toggle when Core turns off.
            if source == .stremio, !enabled, isStremioPlaybackEnabled {
                setPlaybackSource(source, enabled: true)
                continue
            }
            setPlaybackSource(source, enabled: enabled)
        }
        if enabled {
            UserDefaults.standard.set(true, forKey: StremioAddonStore.playbackEnabledKey)
        }
        // Keep other spoken languages hard-off without resetting Advanced toggles
        // inside the active language group.
        let active = activePlaybackLanguageGroup
        for source in PlaybackSourcePreferenceID.allCases
        where source.languageGroup != active && source.languageGroup != .core {
            setPlaybackSource(source, enabled: false)
        }
        NotificationCenter.default.post(name: languageDidChangeNotification, object: active.rawValue)
    }

    /// Preference IDs that belong to the active language, plus Core / Stremio when enabled.
    ///
    /// Policy: the playback language picker still gates language-group scrapers.
    /// Stremio addons are language-agnostic protocol sources — they may resolve
    /// alongside the active language when Stremio playback is on (independently
    /// or via Core). Catalog browsing never requires a language group.
    static func allowedPreferenceIDs() -> Set<PlaybackSourcePreferenceID> {
        var allowed = Set(PlaybackSourcePreferenceID.sources(in: activePlaybackLanguageGroup))
        if isCoreResolversEnabled {
            allowed.formUnion(PlaybackSourcePreferenceID.sources(in: .core))
        } else if isStremioPlaybackEnabled {
            allowed.insert(.stremio)
        }
        return allowed
    }

    static func isProviderAllowed(providerID: String) -> Bool {
        guard let preference = PlaybackSourcePreferenceID.allCases.first(where: {
            $0.matches(providerID: providerID)
        }) else {
            return false
        }
        return allowedPreferenceIDs().contains(preference) && isPlaybackSourceEnabled(preference)
    }

    static func isPlaybackSourceEnabled(_ source: PlaybackSourcePreferenceID) -> Bool {
        if UserDefaults.standard.object(forKey: source.defaultsKey) == nil {
            let allowed = allowedPreferenceIDs().contains(source)
            return allowed && source.defaultEnabled
        }
        return UserDefaults.standard.bool(forKey: source.defaultsKey)
    }

    static func setPlaybackSource(_ source: PlaybackSourcePreferenceID, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: source.defaultsKey)
    }

    private static func applyLanguageGroup(
        _ group: ProviderLanguageGroup,
        coreEnabled: Bool
    ) {
        let selected = group.isSpokenLanguage ? group : .german
        UserDefaults.standard.set(selected.rawValue, forKey: languageGroupKey)
        UserDefaults.standard.set(coreEnabled, forKey: coreResolversKey)
        for source in PlaybackSourcePreferenceID.allCases {
            let enabled: Bool
            if source.languageGroup == selected {
                enabled = true
            } else if source.languageGroup == .core {
                if source == .stremio {
                    enabled = coreEnabled || isStremioPlaybackEnabled
                } else {
                    enabled = coreEnabled
                }
            } else {
                enabled = false
            }
            setPlaybackSource(source, enabled: enabled)
        }
    }
}
