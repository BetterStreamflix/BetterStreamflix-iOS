import Foundation
import Security

/// Debrid-first product decision: BetterStreamflix never runs in-app BitTorrent.
/// Tokens configure popular stream addons (Torrentio / Comet / MediaFusion) so they
/// return HTTP(S) links the NativePlayer can play.
enum StremioDebridService: String, CaseIterable, Identifiable, Codable, Hashable, Sendable {
    case realDebrid
    case allDebrid
    case premiumize
    case torbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .realDebrid: "Real-Debrid"
        case .allDebrid: "AllDebrid"
        case .premiumize: "Premiumize"
        case .torbox: "TorBox"
        }
    }

    var shortTitle: String {
        switch self {
        case .realDebrid: "RD"
        case .allDebrid: "AD"
        case .premiumize: "PM"
        case .torbox: "TB"
        }
    }

    /// Path slug used by Torrentio-style config URLs.
    var torrentioSlug: String {
        switch self {
        case .realDebrid: "realdebrid"
        case .allDebrid: "alldebrid"
        case .premiumize: "premiumize"
        case .torbox: "torbox"
        }
    }

    var blurb: String {
        switch self {
        case .realDebrid: "Most popular debrid for Torrentio / Comet / MediaFusion."
        case .allDebrid: "Alternative debrid accepted by Torrentio and MediaFusion."
        case .premiumize: "Premiumize cloud for Torrentio-style manifests."
        case .torbox: "TorBox debrid for Torrentio and compatible mirrors."
        }
    }
}

struct StremioDebridProfile: Identifiable, Hashable, Sendable {
    let service: StremioDebridService
    var token: String

    var id: String { service.id }
    var isConfigured: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum StremioDebridURLBuilder {
    /// Builds a configured manifest URL for known stream presets.
    static func configuredManifestURL(
        for presetID: String,
        service: StremioDebridService,
        token: String,
        baseManifestURL: URL
    ) -> URL? {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleaned
        let host = (baseManifestURL.host ?? "").lowercased()

        if host.contains("torrentio") || presetID.contains("torrentio") {
            // https://torrentio.strem.fun/realdebrid=TOKEN/manifest.json
            var root = baseManifestURL.deletingLastPathComponent()
            while root.lastPathComponent.contains("=") {
                root = root.deletingLastPathComponent()
            }
            let config = "\(service.torrentioSlug)=\(encoded)"
            return root
                .appendingPathComponent(config)
                .appendingPathComponent("manifest.json")
        }

        if host.contains("comet") || presetID.contains("comet") {
            // Comet ElfHosted: /{base64url-json}/manifest.json (simplified RD-only form).
            let payload: [String: Any] = [
                "debridService": service.torrentioSlug,
                "debridApiKey": cleaned,
                "maxSize": 0,
                "cachedOnly": false,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return baseManifestURL
                .deletingLastPathComponent()
                .appendingPathComponent(b64)
                .appendingPathComponent("manifest.json")
        }

        if host.contains("mediafusion") || presetID.contains("mediafusion") {
            // MediaFusion often uses /{encrypted_config}/manifest.json — for tokens we
            // append a debrid query that many public instances accept, plus a path slug.
            let config = "\(service.torrentioSlug)=\(encoded)"
            return baseManifestURL
                .deletingLastPathComponent()
                .appendingPathComponent(config)
                .appendingPathComponent("manifest.json")
        }

        // Generic fallback: insert config segment before manifest.json
        let config = "\(service.torrentioSlug)=\(encoded)"
        return baseManifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(config)
            .appendingPathComponent("manifest.json")
    }

    static func looksConfigured(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let markers = ["realdebrid=", "alldebrid=", "premiumize=", "torbox=", "debrid"]
        return markers.contains { path.contains($0) }
    }
}

@MainActor
final class StremioDebridStore: ObservableObject {
    static let shared = StremioDebridStore()

    static let preferredServiceKey = "stremio.debrid.preferredService.v1"
    static let adultCatalogsKey = "stremio.catalogs.adultOptIn.v1"
    static let streamTimeoutKey = "stremio.stream.queryTimeout.v1"
    static let maxParallelKey = "stremio.stream.maxParallel.v1"
    private static let keychainService = "com.betterstreamflix.ios.stremio.debrid"

    @Published private(set) var profiles: [StremioDebridProfile] = []
    @Published var preferredService: StremioDebridService {
        didSet {
            UserDefaults.standard.set(preferredService.rawValue, forKey: Self.preferredServiceKey)
        }
    }

    var adultCatalogsOptIn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.adultCatalogsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.adultCatalogsKey)
            objectWillChange.send()
        }
    }

    /// Per-addon stream query timeout in seconds (default 12).
    var streamQueryTimeout: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: Self.streamTimeoutKey)
            return value > 0 ? value : 12
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.streamTimeoutKey)
            objectWillChange.send()
        }
    }

    var maxParallelStreamQueries: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Self.maxParallelKey)
            return value > 0 ? value : 6
        }
        set {
            UserDefaults.standard.set(max(1, min(12, newValue)), forKey: Self.maxParallelKey)
            objectWillChange.send()
        }
    }

    var preferredProfile: StremioDebridProfile? {
        profiles.first { $0.service == preferredService && $0.isConfigured }
            ?? profiles.first(where: \.isConfigured)
    }

    var hasAnyToken: Bool { profiles.contains(where: \.isConfigured) }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.preferredServiceKey),
           let service = StremioDebridService(rawValue: raw) {
            preferredService = service
        } else {
            preferredService = .realDebrid
        }
        reload()
    }

    func reload() {
        profiles = StremioDebridService.allCases.map { service in
            StremioDebridProfile(service: service, token: Self.loadToken(service: service) ?? "")
        }
    }

    func setToken(_ token: String, for service: StremioDebridService) {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            Self.deleteToken(service: service)
        } else {
            Self.saveToken(cleaned, service: service)
        }
        reload()
    }

    func clearAll() {
        for service in StremioDebridService.allCases {
            Self.deleteToken(service: service)
        }
        reload()
    }

    func configuredManifestURL(for curated: StremioCuratedAddon) -> URL? {
        guard let profile = preferredProfile else { return nil }
        return StremioDebridURLBuilder.configuredManifestURL(
            for: curated.id,
            service: profile.service,
            token: profile.token,
            baseManifestURL: curated.manifestURL
        )
    }

    // MARK: - Keychain

    private static func account(for service: StremioDebridService) -> String {
        "debrid.\(service.rawValue)"
    }

    private static func loadToken(service: StremioDebridService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account(for: service),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    private static func saveToken(_ token: String, service: StremioDebridService) {
        deleteToken(service: service)
        guard let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account(for: service),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deleteToken(service: StremioDebridService) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account(for: service),
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Snapshot of the last Stremio playback resolve for empty-state diagnostics.
struct StremioResolveDiagnostics: Sendable, Hashable {
    var queriedAddons: Int = 0
    var playableHTTP: Int = 0
    var skippedTorrent: Int = 0
    var skippedYouTube: Int = 0
    var skippedExternal: Int = 0
    var skippedUnsupportedFormat: Int = 0
    var skippedNeedsConfig: Int = 0
    var failedAddons: Int = 0
    var usedTMDbIdentifier: Bool = false
    var missingIMDb: Bool = false
    var debridConfigured: Bool = false

    var userFacingSummary: String {
        if missingIMDb && !usedTMDbIdentifier {
            return "Stremio needs an IMDb or TMDB id for this title. Open details again after metadata loads, or install a meta addon."
        }
        if queriedAddons == 0 {
            return "No enabled Stremio stream addons. Install Torrentio/Comet with Debrid, or another HTTP stream addon."
        }
        if playableHTTP == 0, skippedTorrent > 0, !debridConfigured {
            return "Addons returned \(skippedTorrent) torrent-only result\(skippedTorrent == 1 ? "" : "s"). Configure Real-Debrid (or another debrid) under Stremio → Debrid, then reinstall Torrentio with your token — BetterStreamflix does not run BitTorrent in-app."
        }
        if playableHTTP == 0, skippedNeedsConfig > 0 {
            return "\(skippedNeedsConfig) addon\(skippedNeedsConfig == 1 ? "" : "s") need configuration. Open Manage plugins and finish setup."
        }
        if playableHTTP == 0, skippedExternal > 0, skippedTorrent == 0 {
            return "Addons only offered external store links. Use Open externally where shown, or install an HTTP/debrid stream addon."
        }
        if playableHTTP == 0, failedAddons == queriedAddons, queriedAddons > 0 {
            return "All Stremio stream addons failed or timed out. Check plugin health and your network."
        }
        if playableHTTP == 0 {
            var parts: [String] = ["Stremio returned no playable HTTP streams."]
            if skippedTorrent > 0 { parts.append("\(skippedTorrent) torrent") }
            if skippedUnsupportedFormat > 0 { parts.append("\(skippedUnsupportedFormat) unsupported format") }
            if skippedYouTube > 0 { parts.append("\(skippedYouTube) YouTube") }
            if skippedExternal > 0 { parts.append("\(skippedExternal) external") }
            if parts.count > 1 {
                return parts[0] + " Skipped: " + parts.dropFirst().joined(separator: ", ") + "."
            }
            return parts[0]
        }
        return "\(playableHTTP) playable Stremio stream\(playableHTTP == 1 ? "" : "s")."
    }
}

enum StremioResolveDiagnosticsStore {
    private static let lock = NSLock()
    private static var latest = StremioResolveDiagnostics()

    static func update(_ value: StremioResolveDiagnostics) {
        lock.withLock { latest = value }
    }

    static func current() -> StremioResolveDiagnostics {
        lock.withLock { latest }
    }
}
