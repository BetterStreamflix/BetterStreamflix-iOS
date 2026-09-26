import Foundation

enum StremioAddonHealth: String, Codable, Hashable, Sendable {
    case unknown
    case healthy
    case degraded
    case unreachable

    var title: String {
        switch self {
        case .unknown: "Not checked"
        case .healthy: "Healthy"
        case .degraded: "Slow"
        case .unreachable: "Unreachable"
        }
    }
}

enum StremioAddonKind: String, Codable, Hashable, Sendable, CaseIterable {
    case catalog
    case stream
    case subtitles
    case mixed

    var title: String {
        switch self {
        case .catalog: "Catalog"
        case .stream: "Stream"
        case .subtitles: "Subtitles"
        case .mixed: "Mixed"
        }
    }
}

struct InstalledStremioAddon: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var manifestURL: URL
    var baseURL: URL
    var name: String
    var version: String?
    var detail: String?
    var logoURL: URL?
    var isEnabled: Bool
    var sortOrder: Int
    var supportsCatalog: Bool
    var supportsMeta: Bool
    var supportsStream: Bool
    var supportsSubtitles: Bool
    var catalogs: [StremioManifestCatalog]
    var health: StremioAddonHealth
    var lastCheckedAt: Date?
    var lastError: String?
    var isCurated: Bool
    var latencyMS: Int?
    var idPrefixes: [String]?
    var resourceTypes: [String]?
    var isAdult: Bool
    var isP2P: Bool
    var isConfigurable: Bool
    var requiresConfiguration: Bool
    var streamSmokeOK: Bool?
    /// Last known remote version from health refresh (for update badges).
    var remoteVersion: String?
    var updateAvailable: Bool {
        guard let remoteVersion, let version, !remoteVersion.isEmpty else { return false }
        return remoteVersion != version
    }

    var transportID: String { id }

    var kind: StremioAddonKind {
        let flags = [supportsCatalog, supportsStream, supportsSubtitles].filter { $0 }.count
        if flags > 1 { return .mixed }
        if supportsStream { return .stream }
        if supportsSubtitles { return .subtitles }
        if supportsCatalog { return .catalog }
        return .mixed
    }

    var capabilitySummary: String {
        var parts: [String] = []
        if supportsCatalog { parts.append("Catalog") }
        if supportsMeta { parts.append("Meta") }
        if supportsStream { parts.append("Stream") }
        if supportsSubtitles { parts.append("Subtitles") }
        return parts.isEmpty ? "No resources" : parts.joined(separator: " · ")
    }

    var needsConfigurationWarning: Bool {
        requiresConfiguration && !StremioDebridURLBuilder.looksConfigured(manifestURL)
    }

    /// Always the addon origin `/configure` — never nested under a Debrid config segment.
    var configurePageURL: URL? {
        guard isConfigurable || requiresConfiguration else { return nil }
        return StremioDebridURLBuilder.configurePageURL(from: manifestURL)
    }

    init(
        id: String,
        manifestURL: URL,
        baseURL: URL,
        name: String,
        version: String? = nil,
        detail: String? = nil,
        logoURL: URL? = nil,
        isEnabled: Bool,
        sortOrder: Int,
        supportsCatalog: Bool,
        supportsMeta: Bool,
        supportsStream: Bool,
        supportsSubtitles: Bool,
        catalogs: [StremioManifestCatalog],
        health: StremioAddonHealth,
        lastCheckedAt: Date? = nil,
        lastError: String? = nil,
        isCurated: Bool,
        latencyMS: Int? = nil,
        idPrefixes: [String]? = nil,
        resourceTypes: [String]? = nil,
        isAdult: Bool = false,
        isP2P: Bool = false,
        isConfigurable: Bool = false,
        requiresConfiguration: Bool = false,
        streamSmokeOK: Bool? = nil,
        remoteVersion: String? = nil
    ) {
        self.id = id
        self.manifestURL = manifestURL
        self.baseURL = baseURL
        self.name = name
        self.version = version
        self.detail = detail
        self.logoURL = logoURL
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.supportsCatalog = supportsCatalog
        self.supportsMeta = supportsMeta
        self.supportsStream = supportsStream
        self.supportsSubtitles = supportsSubtitles
        self.catalogs = catalogs
        self.health = health
        self.lastCheckedAt = lastCheckedAt
        self.lastError = lastError
        self.isCurated = isCurated
        self.latencyMS = latencyMS
        self.idPrefixes = idPrefixes
        self.resourceTypes = resourceTypes
        self.isAdult = isAdult
        self.isP2P = isP2P
        self.isConfigurable = isConfigurable
        self.requiresConfiguration = requiresConfiguration
        self.streamSmokeOK = streamSmokeOK
        self.remoteVersion = remoteVersion
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        manifestURL = try container.decode(URL.self, forKey: .manifestURL)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        supportsCatalog = try container.decodeIfPresent(Bool.self, forKey: .supportsCatalog) ?? false
        supportsMeta = try container.decodeIfPresent(Bool.self, forKey: .supportsMeta) ?? false
        supportsStream = try container.decodeIfPresent(Bool.self, forKey: .supportsStream) ?? false
        supportsSubtitles = try container.decodeIfPresent(Bool.self, forKey: .supportsSubtitles) ?? false
        catalogs = try container.decodeIfPresent([StremioManifestCatalog].self, forKey: .catalogs) ?? []
        health = try container.decodeIfPresent(StremioAddonHealth.self, forKey: .health) ?? .unknown
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        isCurated = try container.decodeIfPresent(Bool.self, forKey: .isCurated) ?? false
        latencyMS = try container.decodeIfPresent(Int.self, forKey: .latencyMS)
        idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
        resourceTypes = try container.decodeIfPresent([String].self, forKey: .resourceTypes)
        isAdult = try container.decodeIfPresent(Bool.self, forKey: .isAdult) ?? false
        isP2P = try container.decodeIfPresent(Bool.self, forKey: .isP2P) ?? false
        isConfigurable = try container.decodeIfPresent(Bool.self, forKey: .isConfigurable) ?? false
        requiresConfiguration = try container.decodeIfPresent(Bool.self, forKey: .requiresConfiguration) ?? false
        streamSmokeOK = try container.decodeIfPresent(Bool.self, forKey: .streamSmokeOK)
        remoteVersion = try container.decodeIfPresent(String.self, forKey: .remoteVersion)
    }

    mutating func apply(manifest: StremioManifest, baseURL: URL) {
        self.baseURL = baseURL
        name = manifest.name
        if let remote = manifest.version {
            if version != nil, version != remote {
                remoteVersion = remote
            } else {
                version = remote
                remoteVersion = remote
            }
        }
        detail = manifest.description
        logoURL = URL(string: manifest.logo ?? "")
        supportsCatalog = manifest.supportsCatalog
        supportsMeta = manifest.supportsMeta
        supportsStream = manifest.supportsStream
        supportsSubtitles = manifest.supportsSubtitles
        idPrefixes = Self.mergedStreamIdPrefixes(from: manifest)
        resourceTypes = Self.mergedStreamTypes(from: manifest)
        isAdult = manifest.isAdult
        isP2P = manifest.isP2P
        isConfigurable = manifest.isConfigurable
        requiresConfiguration = manifest.requiresConfiguration
        catalogs = manifest.catalogs.filter { catalog in
            if catalog.supportsSearch { return true }
            return !catalog.requiresExtras
        }
    }

    /// Prefer stream-resource `idPrefixes` when present; fall back to top-level.
    static func mergedStreamIdPrefixes(from manifest: StremioManifest) -> [String]? {
        let resource = manifest.resource("stream")?.idPrefixes
        if let resource, !resource.isEmpty { return resource }
        return manifest.idPrefixes
    }

    static func mergedStreamTypes(from manifest: StremioManifest) -> [String]? {
        let resource = manifest.resource("stream")?.types
        if let resource, !resource.isEmpty { return resource }
        return manifest.types
    }

    mutating func applyUpdate(from manifest: StremioManifest, baseURL: URL, manifestURL: URL) {
        self.manifestURL = manifestURL
        apply(manifest: manifest, baseURL: baseURL)
        version = manifest.version
        remoteVersion = manifest.version
    }
}

struct StremioCuratedAddon: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let blurb: String
    let manifestURL: URL
    let capabilities: String
    let kind: StremioAddonKind
    /// Popular presets that may be blocked on some networks (still offered).
    let isPopularOptional: Bool
    let networkNote: String?

    init(
        id: String,
        name: String,
        blurb: String,
        manifestURL: URL,
        capabilities: String,
        kind: StremioAddonKind,
        isPopularOptional: Bool = false,
        networkNote: String? = nil
    ) {
        self.id = id
        self.name = name
        self.blurb = blurb
        self.manifestURL = manifestURL
        self.capabilities = capabilities
        self.kind = kind
        self.isPopularOptional = isPopularOptional
        self.networkNote = networkNote
    }
}

enum StremioCuratedCatalog {
    /// Official / reliably reachable remote manifests only — never app-bundled scrapers.
    static var seedDefaults: [StremioCuratedAddon] {
        [
            StremioCuratedAddon(
                id: "com.linvo.cinemeta",
                name: "Cinemeta",
                blurb: "Official Stremio catalogs and metadata for movies and series.",
                manifestURL: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!,
                capabilities: "Catalog · Meta",
                kind: .catalog
            ),
            StremioCuratedAddon(
                id: "org.stremio.cinemeta-catalogs-top",
                name: "Cinemeta Popular",
                blurb: "Top movie and series shelves from the Cinemeta catalog family.",
                manifestURL: URL(string: "https://cinemeta-catalogs.strem.io/top/manifest.json")!,
                capabilities: "Catalog",
                kind: .catalog
            ),
            StremioCuratedAddon(
                id: "tmdb-addon",
                name: "The Movie Database",
                blurb: "TMDB-powered discovery shelves for movies and series.",
                manifestURL: URL(string: "https://94c8cb9f702d-tmdb-addon.baby-beamup.club/manifest.json")!,
                capabilities: "Catalog · Meta",
                kind: .catalog
            ),
            StremioCuratedAddon(
                id: "org.stremio.opensubtitlesv3",
                name: "OpenSubtitles v3",
                blurb: "Community subtitles over the Stremio protocol.",
                manifestURL: URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!,
                capabilities: "Subtitles",
                kind: .subtitles
            ),
        ]
    }

    /// Popular community presets — install on demand; graceful when unreachable.
    static var popularPresets: [StremioCuratedAddon] {
        [
            StremioCuratedAddon(
                id: "com.stremio.torrentio.addon",
                name: "Torrentio",
                blurb: "Popular torrent index. Needs Debrid (Real-Debrid / AllDebrid / …) for in-app HTTP playback — torrents alone never play on iOS.",
                manifestURL: URL(string: "https://torrentio.strem.fun/manifest.json")!,
                capabilities: "Stream (Debrid)",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Cloudflare may block some networks. Prefer Install with Debrid, or paste a working mirror URL."
            ),
            StremioCuratedAddon(
                id: "comet.elfhosted.com",
                name: "Comet",
                blurb: "ElfHosted stream resolver. Configure Debrid for playable HTTP links — no in-app BitTorrent.",
                manifestURL: URL(string: "https://comet.elfhosted.com/manifest.json")!,
                capabilities: "Stream (Debrid)",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Requires a healthy ElfHosted endpoint. Use Install with Debrid after saving a token."
            ),
            StremioCuratedAddon(
                id: "stremio.addons.mediafusion|elfhosted",
                name: "MediaFusion",
                blurb: "Multi-source stream and catalog addon. Pair with Debrid for torrents; HTTP mirrors play directly.",
                manifestURL: URL(string: "https://mediafusion.elfhosted.com/manifest.json")!,
                capabilities: "Stream · Catalog (Debrid)",
                kind: .mixed,
                isPopularOptional: true,
                networkNote: "Install with Debrid for torrent sources."
            ),
            StremioCuratedAddon(
                id: "org.stremio.watchhub",
                name: "WatchHub",
                blurb: "Where to rent or stream titles. Opens external store links in Safari — not in-player HTTP.",
                manifestURL: URL(string: "https://watchhub.strem.io/manifest.json")!,
                capabilities: "External links",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Shows “Open in Safari” actions. Does not feed NativePlayer."
            ),
            StremioCuratedAddon(
                id: "org.stremio.cinemeta-catalogs-imdbRating",
                name: "Worth Watching",
                blurb: "High IMDb-rated catalogs from the Cinemeta family.",
                manifestURL: URL(string: "https://cinemeta-catalogs.strem.io/imdbRating/manifest.json")!,
                capabilities: "Catalog",
                kind: .catalog,
                isPopularOptional: true
            ),
            StremioCuratedAddon(
                id: "xyz.stremio.wizdom",
                name: "Wizdom Subtitles",
                blurb: "Hebrew-focused subtitles via the Stremio protocol (separate from the native Wizdom provider).",
                manifestURL: URL(string: "https://4b139a4b7f94-wizdom-stremio-v2.baby-beamup.club/manifest.json")!,
                capabilities: "Subtitles",
                kind: .subtitles,
                isPopularOptional: true
            ),
            StremioCuratedAddon(
                id: "me.stremio.ktuvit",
                name: "Ktuvit Subtitles",
                blurb: "Ktuvit.me subtitles as a Stremio addon (separate from the native Ktuvit provider).",
                manifestURL: URL(string: "https://4b139a4b7f94-ktuvit-stremio.baby-beamup.club/manifest.json")!,
                capabilities: "Subtitles",
                kind: .subtitles,
                isPopularOptional: true
            ),
            StremioCuratedAddon(
                id: "com.viren070.aiostreams",
                name: "AIOStreams",
                blurb: "All-in-one stream aggregator. Pair with Debrid for cached HTTP playback — no in-app BitTorrent.",
                manifestURL: URL(string: "https://aiostreams.elfhosted.com/stremio/manifest.json")!,
                capabilities: "Stream (Debrid)",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Install with Debrid after saving a token. Configure filters in the addon page if needed."
            ),
            StremioCuratedAddon(
                id: "com.stremio.torrentio.addon.mirror",
                name: "Torrentio (ElfHosted mirror)",
                blurb: "Torrentio mirror host. Use when torrentio.strem.fun is blocked — still needs Debrid for playback.",
                manifestURL: URL(string: "https://torrentio.elfhosted.com/manifest.json")!,
                capabilities: "Stream (Debrid)",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Mirror of Torrentio. Install with Debrid."
            ),
            StremioCuratedAddon(
                id: "com.stremio.annatar",
                name: "Annatar",
                blurb: "Debrid-friendly torrent stream aggregator. Pair with a saved Debrid token for HTTP playback.",
                manifestURL: URL(string: "https://annatar.elfhosted.com/manifest.json")!,
                capabilities: "Stream (Debrid)",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Install with Debrid after saving a token."
            ),
            StremioCuratedAddon(
                id: "community.stremio.torrentio.addon.prowlarr",
                name: "Jackettio",
                blurb: "Jackett/Prowlarr-backed torrent index. Needs Debrid for in-app HTTP — torrents alone never play on iOS.",
                manifestURL: URL(string: "https://jackettio.elfhosted.com/manifest.json")!,
                capabilities: "Stream (Debrid)",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Public ElfHosted Jackettio instance. Prefer Install with Debrid."
            ),
            StremioCuratedAddon(
                id: "com.torbox.stremio",
                name: "TorBox",
                blurb: "Official TorBox Stremio addon. Install with Debrid injects your TorBox API key into the manifest path.",
                manifestURL: URL(string: "https://stremio.torbox.app/manifest.json")!,
                capabilities: "Stream (Debrid)",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Requires a TorBox token. Prefer Install with Debrid."
            ),
        ]
    }

    /// Documented mirror hosts for Torrentio when the primary is blocked.
    static let torrentioMirrorHosts: [String] = [
        "torrentio.strem.fun",
        "torrentio.elfhosted.com",
    ]

    static var allPresets: [StremioCuratedAddon] { seedDefaults + popularPresets }

    /// Hosts / ids that must never appear as community Stremio plugins.
    static let bannedPluginHostFragments: [String] = [
        "pengu.uk",
        "penguplay",
        "com.penguplay",
    ]

    static func isBannedPlugin(url: URL, manifestID: String? = nil) -> Bool {
        let haystack = (url.absoluteString + " " + (manifestID ?? "")).lowercased()
        return bannedPluginHostFragments.contains { haystack.contains($0) }
    }

    static func isDebridStreamPreset(_ curated: StremioCuratedAddon) -> Bool {
        ["torrentio", "comet", "mediafusion", "aiostreams", "annatar", "jackettio", "torbox"].contains {
            curated.id.lowercased().contains($0) || curated.name.lowercased().contains($0)
        }
    }
}

@MainActor
final class StremioAddonStore: ObservableObject {
    static let shared = StremioAddonStore()

    nonisolated(unsafe) static let storageKey = "stremio.addons.installed.v1"
    static let seededKey = "stremio.addons.seeded.v1"
    static let purgedBundledKey = "stremio.addons.purgedBundled.v2"
    static let playbackEnabledKey = "playback.stremio.enabled"
    static let didChangeNotification = Notification.Name("stremio.addons.didChange")

    @Published private(set) var addons: [InstalledStremioAddon] = []
    @Published private(set) var isBusy = false
    @Published private(set) var presetReachability: [String: StremioAddonHealth] = [:]
    @Published var lastInstallError: String?
    @Published private(set) var lastSeedFailures: [String] = []

    private let client: any HTTPClientProtocol
    private let defaults: UserDefaults

    init(client: any HTTPClientProtocol = HTTPClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        addons = Self.load(from: defaults)
        purgeBannedPluginsIfNeeded()
        seedCuratedDefaultsIfNeeded()
    }

    var enabledAddons: [InstalledStremioAddon] {
        addons.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }
    }

    var catalogAddons: [InstalledStremioAddon] {
        enabledAddons.filter { $0.supportsCatalog && !$0.catalogs.isEmpty }
    }

    var streamAddons: [InstalledStremioAddon] {
        enabledAddons.filter(\.supportsStream)
    }

    var subtitleAddons: [InstalledStremioAddon] {
        enabledAddons.filter(\.supportsSubtitles)
    }

    var isPlaybackEnabled: Bool {
        get { AppSetupStore.isStremioPlaybackEnabled }
        set { AppSetupStore.setStremioPlaybackEnabled(newValue) }
    }

    func isInstalled(manifestURL: URL) -> Bool {
        let key = Self.canonicalKey(for: manifestURL)
        return addons.contains {
            Self.canonicalKey(for: $0.manifestURL) == key || $0.id == key
        }
    }

    func isInstalled(curated: StremioCuratedAddon) -> Bool {
        isInstalled(manifestURL: curated.manifestURL)
            || addons.contains { $0.id == curated.id }
    }

    func install(from rawURL: String, curated: Bool = false) async throws -> InstalledStremioAddon {
        guard let manifestURL = StremioManifestURL.parse(rawURL) else {
            throw AppError.decoding("Invalid Stremio addon URL")
        }
        if StremioCuratedCatalog.isBannedPlugin(url: manifestURL) {
            throw AppError.decoding("That URL is an app-bundled source, not a Stremio community addon")
        }
        isBusy = true
        lastInstallError = nil
        defer { isBusy = false }
        let loaded = try await StremioAddonClient.loadManifest(from: manifestURL, client: client)
        if StremioCuratedCatalog.isBannedPlugin(url: manifestURL, manifestID: loaded.manifest.id) {
            throw AppError.decoding("That addon is not a community Stremio plugin")
        }
        if let existingIndex = addons.firstIndex(where: {
            $0.id == loaded.manifest.id
                || Self.canonicalKey(for: $0.manifestURL) == Self.canonicalKey(for: manifestURL)
        }) {
            var existing = addons[existingIndex]
            existing.manifestURL = manifestURL
            existing.apply(manifest: loaded.manifest, baseURL: loaded.baseURL)
            existing.health = .healthy
            existing.lastCheckedAt = Date()
            existing.lastError = nil
            existing.isCurated = existing.isCurated || curated
            addons[existingIndex] = existing
            persist()
            return existing
        }
        var addon = InstalledStremioAddon(
            id: loaded.manifest.id,
            manifestURL: manifestURL,
            baseURL: loaded.baseURL,
            name: loaded.manifest.name,
            version: loaded.manifest.version,
            detail: loaded.manifest.description,
            logoURL: URL(string: loaded.manifest.logo ?? ""),
            isEnabled: true,
            sortOrder: (addons.map(\.sortOrder).max() ?? -1) + 1,
            supportsCatalog: loaded.manifest.supportsCatalog,
            supportsMeta: loaded.manifest.supportsMeta,
            supportsStream: loaded.manifest.supportsStream,
            supportsSubtitles: loaded.manifest.supportsSubtitles,
            catalogs: [],
            health: .healthy,
            lastCheckedAt: Date(),
            lastError: nil,
            isCurated: curated,
            latencyMS: nil,
            idPrefixes: loaded.manifest.idPrefixes,
            resourceTypes: loaded.manifest.types,
            isAdult: loaded.manifest.isAdult,
            isP2P: loaded.manifest.isP2P,
            isConfigurable: loaded.manifest.isConfigurable,
            requiresConfiguration: loaded.manifest.requiresConfiguration,
            streamSmokeOK: nil
        )
        addon.apply(manifest: loaded.manifest, baseURL: loaded.baseURL)
        addons.append(addon)
        persist()
        return addon
    }

    func installCurated(_ curated: StremioCuratedAddon) async throws {
        _ = try await install(from: curated.manifestURL.absoluteString, curated: true)
    }

    /// One-tap install with preferred Debrid token baked into the manifest URL.
    func installCuratedWithDebrid(
        _ curated: StremioCuratedAddon,
        debrid: StremioDebridStore = .shared
    ) async throws {
        guard let url = debrid.configuredManifestURL(for: curated) else {
            throw AppError.decoding(
                "Open Configure for \(curated.name) — automatic Debrid URL isn’t available for this addon (or save a matching token: TorBox for TorBox, any for Torrentio/Comet)."
            )
        }
        _ = try await install(from: url.absoluteString, curated: true)
    }

    /// Rewrite installed Debrid stream addons to the preferred token/service (one-tap rebind).
    @discardableResult
    func rebindDebridProfiles(debrid: StremioDebridStore = .shared) async throws -> Int {
        guard debrid.hasAnyToken else {
            throw AppError.decoding("Save a Debrid token first")
        }
        var rebound = 0
        let targets = addons.filter { addon in
            addon.supportsStream && (
                StremioDebridURLBuilder.looksConfigured(addon.manifestURL)
                    || ["torrentio", "comet", "mediafusion", "aiostreams", "annatar", "jackettio", "torbox"].contains {
                        addon.id.lowercased().contains($0) || addon.name.lowercased().contains($0)
                    }
            )
        }
        for addon in targets {
            let bare = StremioDebridURLBuilder.bareManifestURL(from: addon.manifestURL)
            let host = (addon.manifestURL.host ?? "").lowercased()
            let wantsTorBox = host.contains("torbox") || addon.id.lowercased().contains("torbox")
            let profile: StremioDebridProfile?
            if wantsTorBox {
                profile = debrid.profiles.first(where: { $0.service == .torbox && $0.isConfigured })
            } else {
                profile = debrid.preferredProfile
            }
            guard let profile else { continue }
            guard let url = StremioDebridURLBuilder.configuredManifestURL(
                for: addon.id,
                service: profile.service,
                token: profile.token,
                baseManifestURL: bare,
                options: debrid.installOptions
            ) else { continue }
            do {
                _ = try await install(from: url.absoluteString, curated: addon.isCurated)
                rebound += 1
            } catch {
                continue
            }
        }
        await StremioStreamSessionCache.shared.clear()
        return rebound
    }

    /// Apply a pending remote version update while keeping enabled/sortOrder.
    func applyPendingUpdate(for addon: InstalledStremioAddon) async throws {
        guard let index = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        let loaded = try await StremioAddonClient.loadManifest(from: addon.manifestURL, client: client)
        addons[index].applyUpdate(
            from: loaded.manifest,
            baseURL: loaded.baseURL,
            manifestURL: addon.manifestURL
        )
        addons[index].health = .healthy
        addons[index].lastCheckedAt = Date()
        addons[index].lastError = nil
        persist()
    }

    var addonsWithUpdates: [InstalledStremioAddon] {
        addons.filter(\.updateAvailable)
    }

    func remove(_ addon: InstalledStremioAddon) {
        addons.removeAll { $0.id == addon.id }
        renumber()
        persist()
    }

    func setEnabled(_ addon: InstalledStremioAddon, enabled: Bool) {
        guard let index = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        addons[index].isEnabled = enabled
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        addons.move(fromOffsets: source, toOffset: destination)
        renumber()
        persist()
    }

    func refreshHealth(for addon: InstalledStremioAddon) async {
        guard let index = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        let started = Date()
        do {
            let loaded = try await StremioAddonClient.loadManifest(
                from: addon.manifestURL,
                client: client
            )
            let elapsed = Date().timeIntervalSince(started)
            let ms = Int(elapsed * 1000)
            addons[index].apply(manifest: loaded.manifest, baseURL: loaded.baseURL)
            addons[index].health = elapsed > 4 ? .degraded : .healthy
            addons[index].latencyMS = ms
            addons[index].lastCheckedAt = Date()
            addons[index].lastError = nil
            if let remote = loaded.manifest.version {
                addons[index].remoteVersion = remote
            }
        } catch {
            addons[index].health = .unreachable
            addons[index].lastCheckedAt = Date()
            addons[index].lastError = error.localizedDescription
            addons[index].latencyMS = nil
        }
        persist()
    }

    /// Smoke-test stream resource with known sample IDs (IMDb + TMDB).
    func smokeTestStream(for addon: InstalledStremioAddon) async {
        guard let index = addons.firstIndex(where: { $0.id == addon.id }),
              addon.supportsStream else { return }
        let samples = ["tt0133093", "tmdb:603", "tt0944947:1:1"]
        var ok = false
        var lastError: String?
        for sample in samples {
            let type = sample.contains(":") && sample.split(separator: ":").count >= 3 ? "series" : "movie"
            do {
                let client = StremioAddonClient(client: self.client, baseURL: addon.baseURL)
                _ = try await client.streams(type: type, id: sample)
                ok = true
                break
            } catch {
                lastError = error.localizedDescription
            }
        }
        addons[index].streamSmokeOK = ok
        if ok {
            if addons[index].health == .unknown {
                addons[index].health = .healthy
            }
            addons[index].lastError = nil
        } else {
            addons[index].lastError = lastError
        }
        persist()
    }

    func refreshAllHealth() async {
        await withTaskGroup(of: Void.self) { group in
            for addon in addons {
                group.addTask { @MainActor in
                    await self.refreshHealth(for: addon)
                }
            }
        }
    }

    /// Throttled foreground health pass so dead hosts don’t keep eating stream slots.
    func refreshEnabledStreamHealth() async {
        let targets = addons.filter(\.isEnabled)
        await withTaskGroup(of: Void.self) { group in
            for addon in targets {
                group.addTask { @MainActor in
                    await self.refreshHealth(for: addon)
                }
            }
        }
    }

    func probePopularPresets() async {
        await withTaskGroup(of: (String, StremioAddonHealth).self) { group in
            for preset in StremioCuratedCatalog.popularPresets {
                group.addTask {
                    let started = Date()
                    do {
                        _ = try await StremioAddonClient.loadManifest(
                            from: preset.manifestURL,
                            client: self.client
                        )
                        let elapsed = Date().timeIntervalSince(started)
                        return (preset.id, elapsed > 4 ? .degraded : .healthy)
                    } catch {
                        return (preset.id, .unreachable)
                    }
                }
            }
            var map: [String: StremioAddonHealth] = [:]
            for await pair in group {
                map[pair.0] = pair.1
            }
            presetReachability = map
        }
    }

    /// Export installed addon list as JSON (A8 / N4).
    func exportAddonListJSON() throws -> Data {
        let payload = addons.map {
            [
                "id": $0.id,
                "name": $0.name,
                "manifestURL": $0.manifestURL.absoluteString,
                "enabled": $0.isEnabled ? "1" : "0",
            ]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    func importAddonListJSON(_ data: Data) async throws -> Int {
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AppError.decoding("Invalid Stremio addon list")
        }
        var count = 0
        for entry in raw {
            guard let url = entry["manifestURL"] as? String else { continue }
            do {
                var installed = try await install(from: url, curated: false)
                if let enabled = entry["enabled"] as? String {
                    setEnabled(installed, enabled: enabled != "0")
                }
                _ = installed
                count += 1
            } catch {
                continue
            }
        }
        return count
    }

    /// Snapshot safe for background playback workers — installed community addons only.
    nonisolated static func snapshotStreamBaseURLs(
        defaults: UserDefaults = .standard
    ) -> [(id: String, name: String, baseURL: URL)] {
        snapshotStreamAddons(defaults: defaults).map { ($0.id, $0.name, $0.baseURL) }
    }

    nonisolated static func snapshotStreamAddons(
        defaults: UserDefaults = .standard
    ) -> [(id: String, name: String, baseURL: URL, idPrefixes: [String]?, types: [String]?, requiresConfig: Bool, manifestURL: URL?, health: StremioAddonHealth)] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InstalledStremioAddon].self, from: data) else {
            return []
        }
        let adultOK = defaults.bool(forKey: StremioDebridStore.adultCatalogsKey)
        return decoded
            .filter {
                $0.isEnabled
                    && $0.supportsStream
                    && !StremioCuratedCatalog.isBannedPlugin(url: $0.manifestURL, manifestID: $0.id)
                    && (adultOK || !$0.isAdult)
            }
            .sorted { lhs, rhs in
                // Deprioritize unhealthy / slow addons (F2).
                let lh = healthRank(lhs.health)
                let rh = healthRank(rhs.health)
                if lh != rh { return lh < rh }
                return lhs.sortOrder < rhs.sortOrder
            }
            .map {
                (
                    $0.id,
                    $0.name,
                    $0.baseURL,
                    $0.idPrefixes,
                    $0.resourceTypes,
                    $0.requiresConfiguration,
                    $0.manifestURL as URL?,
                    $0.health
                )
            }
    }

    nonisolated static func snapshotSubtitleBaseURLs(
        defaults: UserDefaults = .standard
    ) -> [(id: String, name: String, baseURL: URL)] {
        snapshotSubtitleAddons(defaults: defaults).map { ($0.id, $0.name, $0.baseURL) }
    }

    nonisolated static func snapshotSubtitleAddons(
        defaults: UserDefaults = .standard
    ) -> [(id: String, name: String, baseURL: URL, idPrefixes: [String]?)] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InstalledStremioAddon].self, from: data) else {
            return []
        }
        return decoded
            .filter {
                $0.isEnabled
                    && $0.supportsSubtitles
                    && !StremioCuratedCatalog.isBannedPlugin(url: $0.manifestURL, manifestID: $0.id)
            }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0.id, $0.name, $0.baseURL, $0.idPrefixes) }
    }

    nonisolated private static func healthRank(_ health: StremioAddonHealth) -> Int {
        switch health {
        case .healthy: 0
        case .unknown: 1
        case .degraded: 2
        case .unreachable: 3
        }
    }

    private func purgeBannedPluginsIfNeeded() {
        guard !defaults.bool(forKey: Self.purgedBundledKey) else {
            // Still scrub if anything banned reappears.
            let before = addons.count
            addons.removeAll {
                StremioCuratedCatalog.isBannedPlugin(url: $0.manifestURL, manifestID: $0.id)
            }
            if addons.count != before {
                renumber()
                persist()
            }
            return
        }
        defaults.set(true, forKey: Self.purgedBundledKey)
        let before = addons.count
        addons.removeAll {
            StremioCuratedCatalog.isBannedPlugin(url: $0.manifestURL, manifestID: $0.id)
        }
        if addons.count != before {
            renumber()
            persist()
        }
        // Force a fresh curated seed without banned plugins.
        defaults.set(false, forKey: Self.seededKey)
    }

    private func seedCuratedDefaultsIfNeeded() {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)
        Task { await seedCuratedDefaults() }
    }

    func seedCuratedDefaults() async {
        var failures: [String] = []
        for curated in StremioCuratedCatalog.seedDefaults where !isInstalled(curated: curated) {
            do {
                _ = try await install(from: curated.manifestURL.absoluteString, curated: true)
            } catch {
                failures.append("\(curated.name): \(error.localizedDescription)")
            }
        }
        lastSeedFailures = failures
        if defaults.object(forKey: Self.playbackEnabledKey) == nil,
           AppSetupStore.isPlaybackSourceEnabled(.stremio) {
            defaults.set(true, forKey: Self.playbackEnabledKey)
        }
    }

    private func renumber() {
        for index in addons.indices {
            addons[index].sortOrder = index
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(addons) {
            defaults.set(data, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private static func load(from defaults: UserDefaults) -> [InstalledStremioAddon] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InstalledStremioAddon].self, from: data) else {
            return []
        }
        return decoded
            .filter { !StremioCuratedCatalog.isBannedPlugin(url: $0.manifestURL, manifestID: $0.id) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    static func canonicalKey(for url: URL) -> String {
        var value = url.absoluteString.lowercased()
        if value.hasSuffix("/manifest.json") {
            value.removeLast("/manifest.json".count)
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
