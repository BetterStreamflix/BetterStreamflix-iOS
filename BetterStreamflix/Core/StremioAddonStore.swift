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

    mutating func apply(manifest: StremioManifest, baseURL: URL) {
        self.baseURL = baseURL
        name = manifest.name
        version = manifest.version
        detail = manifest.description
        logoURL = URL(string: manifest.logo ?? "")
        supportsCatalog = manifest.supportsCatalog
        supportsMeta = manifest.supportsMeta
        supportsStream = manifest.supportsStream
        supportsSubtitles = manifest.supportsSubtitles
        catalogs = manifest.catalogs.filter { catalog in
            // Keep browsable catalogs; skip ones that require search-only extras.
            if catalog.supportsSearch { return true }
            return !catalog.requiresExtras
        }
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
                blurb: "The most popular Stremio stream addon. May be blocked on some networks.",
                manifestURL: URL(string: "https://torrentio.strem.fun/manifest.json")!,
                capabilities: "Stream",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Cloudflare may block some networks — paste a working mirror if install fails."
            ),
            StremioCuratedAddon(
                id: "comet.elfhosted.com",
                name: "Comet",
                blurb: "ElfHosted stream resolver for movies and series.",
                manifestURL: URL(string: "https://comet.elfhosted.com/manifest.json")!,
                capabilities: "Stream",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "Requires a healthy ElfHosted endpoint."
            ),
            StremioCuratedAddon(
                id: "stremio.addons.mediafusion|elfhosted",
                name: "MediaFusion",
                blurb: "Multi-source stream and catalog addon (ElfHosted).",
                manifestURL: URL(string: "https://mediafusion.elfhosted.com/manifest.json")!,
                capabilities: "Stream · Catalog",
                kind: .mixed,
                isPopularOptional: true
            ),
            StremioCuratedAddon(
                id: "org.stremio.watchhub",
                name: "WatchHub",
                blurb: "Shows where titles are available to rent or stream (external deep links).",
                manifestURL: URL(string: "https://watchhub.strem.io/manifest.json")!,
                capabilities: "Stream (external)",
                kind: .stream,
                isPopularOptional: true,
                networkNote: "External store links only — not direct in-player HTTP."
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
                blurb: "Hebrew-focused subtitles via Stremio protocol.",
                manifestURL: URL(string: "https://4b139a4b7f94-wizdom-stremio-v2.baby-beamup.club/manifest.json")!,
                capabilities: "Subtitles",
                kind: .subtitles,
                isPopularOptional: true
            ),
            StremioCuratedAddon(
                id: "me.stremio.ktuvit",
                name: "Ktuvit Subtitles",
                blurb: "Ktuvit.me subtitles exposed as a Stremio addon.",
                manifestURL: URL(string: "https://4b139a4b7f94-ktuvit-stremio.baby-beamup.club/manifest.json")!,
                capabilities: "Subtitles",
                kind: .subtitles,
                isPopularOptional: true
            ),
        ]
    }

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
}

@MainActor
final class StremioAddonStore: ObservableObject {
    static let shared = StremioAddonStore()

    static let storageKey = "stremio.addons.installed.v1"
    static let seededKey = "stremio.addons.seeded.v1"
    static let purgedBundledKey = "stremio.addons.purgedBundled.v2"
    static let playbackEnabledKey = "playback.stremio.enabled"
    static let didChangeNotification = Notification.Name("stremio.addons.didChange")

    @Published private(set) var addons: [InstalledStremioAddon] = []
    @Published private(set) var isBusy = false
    @Published private(set) var presetReachability: [String: StremioAddonHealth] = [:]
    @Published var lastInstallError: String?

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
            latencyMS: nil
        )
        addon.apply(manifest: loaded.manifest, baseURL: loaded.baseURL)
        addons.append(addon)
        persist()
        return addon
    }

    func installCurated(_ curated: StremioCuratedAddon) async throws {
        _ = try await install(from: curated.manifestURL.absoluteString, curated: true)
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
        } catch {
            addons[index].health = .unreachable
            addons[index].lastCheckedAt = Date()
            addons[index].lastError = error.localizedDescription
            addons[index].latencyMS = nil
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

    /// Snapshot safe for background playback workers — installed community addons only.
    nonisolated static func snapshotStreamBaseURLs(
        defaults: UserDefaults = .standard
    ) -> [(id: String, name: String, baseURL: URL)] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InstalledStremioAddon].self, from: data) else {
            return []
        }
        return decoded
            .filter {
                $0.isEnabled
                    && $0.supportsStream
                    && !StremioCuratedCatalog.isBannedPlugin(url: $0.manifestURL, manifestID: $0.id)
            }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0.id, $0.name, $0.baseURL) }
    }

    nonisolated static func snapshotSubtitleBaseURLs(
        defaults: UserDefaults = .standard
    ) -> [(id: String, name: String, baseURL: URL)] {
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
            .map { ($0.id, $0.name, $0.baseURL) }
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
        for curated in StremioCuratedCatalog.seedDefaults where !isInstalled(curated: curated) {
            do {
                _ = try await install(from: curated.manifestURL.absoluteString, curated: true)
            } catch {
                // Best-effort seed; user can retry from Settings.
            }
        }
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
