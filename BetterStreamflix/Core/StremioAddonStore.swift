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

    var transportID: String { id }

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
        catalogs = manifest.catalogs.filter { !$0.requiresExtras || $0.supportsSearch }
    }
}

struct StremioCuratedAddon: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let blurb: String
    let manifestURL: URL
    let capabilities: String
}

enum StremioCuratedCatalog {
    static var bundledPenguManifestURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ExternalStreamAddonManifestURL") as? String else {
            return nil
        }
        return StremioManifestURL.parse(raw)
    }

    static var defaults: [StremioCuratedAddon] {
        var items: [StremioCuratedAddon] = [
            StremioCuratedAddon(
                id: "com.linvo.cinemeta",
                name: "Cinemeta",
                blurb: "Official movie and series catalogs with rich metadata.",
                manifestURL: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!,
                capabilities: "Catalog · Meta"
            ),
            StremioCuratedAddon(
                id: "tmdb-addon",
                name: "The Movie Database",
                blurb: "TMDB-powered discovery shelves for movies and series.",
                manifestURL: URL(string: "https://94c8cb9f702d-tmdb-addon.baby-beamup.club/manifest.json")!,
                capabilities: "Catalog · Meta"
            ),
            StremioCuratedAddon(
                id: "org.stremio.opensubtitlesv3",
                name: "OpenSubtitles v3",
                blurb: "Community subtitles resolved through the Stremio protocol.",
                manifestURL: URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!,
                capabilities: "Subtitles"
            ),
        ]
        if let pengu = bundledPenguManifestURL {
            items.insert(
                StremioCuratedAddon(
                    id: "com.penguplay",
                    name: "PenguPlay",
                    blurb: "Direct HTTP streams wired into the native player.",
                    manifestURL: pengu,
                    capabilities: "Stream · Subtitles"
                ),
                at: 1
            )
        }
        return items
    }
}

@MainActor
final class StremioAddonStore: ObservableObject {
    static let shared = StremioAddonStore()

    static let storageKey = "stremio.addons.installed.v1"
    static let seededKey = "stremio.addons.seeded.v1"
    static let playbackEnabledKey = "playback.stremio.enabled"
    static let didChangeNotification = Notification.Name("stremio.addons.didChange")

    @Published private(set) var addons: [InstalledStremioAddon] = []
    @Published private(set) var isBusy = false
    @Published var lastInstallError: String?

    private let client: any HTTPClientProtocol
    private let defaults: UserDefaults

    init(client: any HTTPClientProtocol = HTTPClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        addons = Self.load(from: defaults)
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
        return addons.contains { Self.canonicalKey(for: $0.manifestURL) == key || $0.id == key }
    }

    func install(from rawURL: String, curated: Bool = false) async throws -> InstalledStremioAddon {
        guard let manifestURL = StremioManifestURL.parse(rawURL) else {
            throw AppError.decoding("Invalid Stremio addon URL")
        }
        isBusy = true
        lastInstallError = nil
        defer { isBusy = false }
        let loaded = try await StremioAddonClient.loadManifest(from: manifestURL, client: client)
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
            catalogs: loaded.manifest.catalogs.filter { !$0.requiresExtras || $0.supportsSearch },
            health: .healthy,
            lastCheckedAt: Date(),
            lastError: nil,
            isCurated: curated
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
            addons[index].apply(manifest: loaded.manifest, baseURL: loaded.baseURL)
            addons[index].health = elapsed > 4 ? .degraded : .healthy
            addons[index].lastCheckedAt = Date()
            addons[index].lastError = nil
        } catch {
            addons[index].health = .unreachable
            addons[index].lastCheckedAt = Date()
            addons[index].lastError = error.localizedDescription
        }
        persist()
    }

    func refreshAllHealth() async {
        for addon in addons {
            await refreshHealth(for: addon)
        }
    }

    /// Snapshot safe for background playback workers.
    nonisolated static func snapshotStreamBaseURLs(
        defaults: UserDefaults = .standard
    ) -> [(id: String, name: String, baseURL: URL)] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InstalledStremioAddon].self, from: data) else {
            return fallbackBundledStream()
        }
        let enabled = decoded
            .filter { $0.isEnabled && $0.supportsStream }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0.id, $0.name, $0.baseURL) }
        return enabled.isEmpty ? fallbackBundledStream() : enabled
    }

    nonisolated static func snapshotSubtitleBaseURLs(
        defaults: UserDefaults = .standard
    ) -> [(id: String, name: String, baseURL: URL)] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InstalledStremioAddon].self, from: data) else {
            return fallbackBundledStream()
        }
        let enabled = decoded
            .filter { $0.isEnabled && $0.supportsSubtitles }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { ($0.id, $0.name, $0.baseURL) }
        if !enabled.isEmpty { return enabled }
        return fallbackBundledStream()
    }

    nonisolated private static func fallbackBundledStream() -> [(id: String, name: String, baseURL: URL)] {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ExternalStreamAddonManifestURL") as? String,
              let manifest = StremioManifestURL.parse(raw) else { return [] }
        return [("bundled-external", "External", manifest.deletingLastPathComponent())]
    }

    private func seedCuratedDefaultsIfNeeded() {
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)
        Task { await seedCuratedDefaults() }
    }

    func seedCuratedDefaults() async {
        for curated in StremioCuratedCatalog.defaults where !isInstalled(manifestURL: curated.manifestURL) {
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
        return decoded.sorted { $0.sortOrder < $1.sortOrder }
    }

    private static func canonicalKey(for url: URL) -> String {
        var value = url.absoluteString.lowercased()
        if value.hasSuffix("/manifest.json") {
            value.removeLast("/manifest.json".count)
        }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
