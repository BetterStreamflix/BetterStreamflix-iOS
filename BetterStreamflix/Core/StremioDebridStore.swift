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

/// Live account snapshot from a debrid provider API.
struct StremioDebridAccountStatus: Hashable, Sendable {
    var username: String?
    var email: String?
    var premiumDays: Int?
    var isPremium: Bool
    var points: Int?
    var detail: String?
    var checkedAt: Date

    var badgeTitle: String {
        if isPremium {
            if let days = premiumDays { return "Premium · \(days)d" }
            return "Premium"
        }
        return detail ?? "Check failed"
    }
}

/// Options baked into one-tap Debrid installs (Torrentio / Comet / MediaFusion).
struct StremioDebridInstallOptions: Hashable, Sendable {
    var cachedOnly: Bool
    var qualities: [String]
    var maxSizeGB: Int

    static let `default` = StremioDebridInstallOptions(
        cachedOnly: false,
        qualities: ["4k", "1080p", "720p"],
        maxSizeGB: 0
    )

    static let fastCached = StremioDebridInstallOptions(
        cachedOnly: true,
        qualities: ["1080p", "720p"],
        maxSizeGB: 8
    )

    static let quality1080 = StremioDebridInstallOptions(
        cachedOnly: false,
        qualities: ["1080p", "720p"],
        maxSizeGB: 0
    )
}

enum StremioDebridURLBuilder {
    /// Builds a configured manifest URL for known stream presets.
    static func configuredManifestURL(
        for presetID: String,
        service: StremioDebridService,
        token: String,
        baseManifestURL: URL,
        options: StremioDebridInstallOptions = .default
    ) -> URL? {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleaned
        let host = (baseManifestURL.host ?? "").lowercased()
        let id = presetID.lowercased()

        if host.contains("torrentio") || id.contains("torrentio") {
            var root = baseManifestURL.deletingLastPathComponent()
            while root.lastPathComponent.contains("=") || root.lastPathComponent.contains("|") {
                root = root.deletingLastPathComponent()
            }
            var segments: [String] = ["\(service.torrentioSlug)=\(encoded)"]
            if options.cachedOnly {
                segments.append("cached=true")
            }
            if !options.qualities.isEmpty {
                let filter = options.qualities.joined(separator: ",")
                segments.append("qualityfilter=\(filter)")
            }
            if options.maxSizeGB > 0 {
                segments.append("maxsize=\(options.maxSizeGB)")
            }
            let config = segments.joined(separator: "|")
            return root
                .appendingPathComponent(config)
                .appendingPathComponent("manifest.json")
        }

        if host.contains("comet") || id.contains("comet") {
            let payload: [String: Any] = [
                "debridService": service.torrentioSlug,
                "debridApiKey": cleaned,
                "maxSize": options.maxSizeGB,
                "cachedOnly": options.cachedOnly,
                "resolutions": options.qualities.isEmpty
                    ? ["2160p", "1080p", "720p"]
                    : options.qualities.map { $0 == "4k" ? "2160p" : $0 },
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            var root = baseManifestURL.deletingLastPathComponent()
            // Strip previous config segment when rebinding.
            if root.lastPathComponent.count > 24, !root.lastPathComponent.contains(".") {
                root = root.deletingLastPathComponent()
            }
            return root
                .appendingPathComponent(b64)
                .appendingPathComponent("manifest.json")
        }

        if host.contains("mediafusion") || id.contains("mediafusion") {
            // Prefer query-style when possible; many public instances also accept path slug.
            var root = baseManifestURL.deletingLastPathComponent()
            while root.lastPathComponent.contains("=") {
                root = root.deletingLastPathComponent()
            }
            var segments = ["\(service.torrentioSlug)=\(encoded)"]
            if options.cachedOnly { segments.append("cached=true") }
            let config = segments.joined(separator: "|")
            return root
                .appendingPathComponent(config)
                .appendingPathComponent("manifest.json")
        }

        if host.contains("aiostreams") || id.contains("aiostreams") {
            var root = baseManifestURL.deletingLastPathComponent()
            while root.lastPathComponent.contains("=") {
                root = root.deletingLastPathComponent()
            }
            let config = "\(service.torrentioSlug)=\(encoded)"
            return root
                .appendingPathComponent(config)
                .appendingPathComponent("manifest.json")
        }

        // TorBox official addon embeds the API key as a path segment.
        if host.contains("torbox") || id.contains("torbox") {
            return URL(string: "https://stremio.torbox.app/\(encoded)/manifest.json")
        }

        let config = "\(service.torrentioSlug)=\(encoded)"
        return baseManifestURL
            .deletingLastPathComponent()
            .appendingPathComponent(config)
            .appendingPathComponent("manifest.json")
    }

    static func looksConfigured(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let host = (url.host ?? "").lowercased()
        if host.contains("torbox.app"), path.split(separator: "/").count >= 2 {
            return true
        }
        let markers = ["realdebrid=", "alldebrid=", "premiumize=", "torbox=", "debrid"]
        return markers.contains { path.contains($0) }
    }

    /// Detect which debrid service a configured manifest URL is bound to.
    static func boundService(in url: URL) -> StremioDebridService? {
        let path = url.path.lowercased()
        let host = (url.host ?? "").lowercased()
        if host.contains("torbox.app"), path.split(separator: "/").count >= 2 {
            return .torbox
        }
        for service in StremioDebridService.allCases {
            if path.contains("\(service.torrentioSlug)=") { return service }
        }
        return nil
    }

    /// Strip config path segments so we can rebuild with a fresh token.
    static func bareManifestURL(from url: URL) -> URL {
        var root = url
        if root.lastPathComponent.lowercased() == "manifest.json" {
            root = root.deletingLastPathComponent()
        }
        while looksConfigured(root.appendingPathComponent("manifest.json"))
            || root.lastPathComponent.contains("=")
            || (root.lastPathComponent.count > 24 && !root.lastPathComponent.contains("."))
        {
            let parent = root.deletingLastPathComponent()
            if parent.path == root.path { break }
            root = parent
        }
        return root.appendingPathComponent("manifest.json")
    }
}

/// Validates debrid API tokens against provider endpoints.
enum StremioDebridAccountClient {
    static func validate(
        service: StremioDebridService,
        token: String,
        client: any HTTPClientProtocol = HTTPClient()
    ) async -> StremioDebridAccountStatus {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return StremioDebridAccountStatus(
                isPremium: false,
                detail: "No token",
                checkedAt: Date()
            )
        }
        do {
            switch service {
            case .realDebrid:
                return try await validateRealDebrid(token: cleaned, client: client)
            case .allDebrid:
                return try await validateAllDebrid(token: cleaned, client: client)
            case .premiumize:
                return try await validatePremiumize(token: cleaned, client: client)
            case .torbox:
                return try await validateTorBox(token: cleaned, client: client)
            }
        } catch {
            return StremioDebridAccountStatus(
                isPremium: false,
                detail: error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    private static func validateRealDebrid(
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> StremioDebridAccountStatus {
        let url = URL(string: "https://api.real-debrid.com/rest/1.0/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await client.data(for: request)
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
        let username = json["username"] as? String
            let premium = (json["premium"] as? Int).map { $0 > 0 }
                ?? ((json["type"] as? String)?.lowercased() == "premium")
                ?? false
            let days = json["expiration"] as? String
            let premiumDays: Int?
            if let days, let expiry = ISO8601DateFormatter().date(from: days) {
                premiumDays = max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0)
            } else {
                premiumDays = json["premium"] as? Int
            }
            return StremioDebridAccountStatus(
                username: username,
                email: json["email"] as? String,
                premiumDays: premiumDays,
                isPremium: premium,
                points: json["points"] as? Int,
                detail: premium ? nil : "Not premium",
                checkedAt: Date()
            )
    }

    private static func validateAllDebrid(
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> StremioDebridAccountStatus {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let url = URL(string: "https://api.alldebrid.com/v4/user?agent=BetterStreamflix&apikey=\(encoded)")!
        let response = try await client.data(for: URLRequest(url: url))
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
        let dataObj = json["data"] as? [String: Any]
        let user = dataObj?["user"] as? [String: Any] ?? dataObj ?? [:]
        let isPremium = (user["isPremium"] as? Bool) ?? ((user["premiumUntil"] as? Int ?? 0) > 0)
        let premiumUntil = user["premiumUntil"] as? Int
        let premiumDays: Int?
        if let premiumUntil {
            let expiry = Date(timeIntervalSince1970: TimeInterval(premiumUntil))
            premiumDays = max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0)
        } else {
            premiumDays = nil
        }
        return StremioDebridAccountStatus(
            username: user["username"] as? String,
            email: user["email"] as? String,
            premiumDays: premiumDays,
            isPremium: isPremium,
            points: user["loyaltyPoints"] as? Int,
            detail: isPremium ? nil : "Not premium",
            checkedAt: Date()
        )
    }

    private static func validatePremiumize(
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> StremioDebridAccountStatus {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let url = URL(string: "https://www.premiumize.me/api/account/info?apikey=\(encoded)")!
        let response = try await client.data(for: URLRequest(url: url))
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
        let status = (json["status"] as? String)?.lowercased()
        let isPremium = status == "success" && ((json["premium_until"] as? Int) != nil || json["type"] as? String == "premium")
        let premiumUntil = json["premium_until"] as? Int
        let premiumDays: Int?
        if let premiumUntil {
            let expiry = Date(timeIntervalSince1970: TimeInterval(premiumUntil))
            premiumDays = max(0, Calendar.current.dateComponents([.day], from: Date(), to: expiry).day ?? 0)
        } else {
            premiumDays = nil
        }
        return StremioDebridAccountStatus(
            username: json["customer_id"].map { "\($0)" },
            email: json["email"] as? String,
            premiumDays: premiumDays,
            isPremium: isPremium || status == "success",
            points: nil,
            detail: status == "success" ? nil : (json["message"] as? String ?? "Check failed"),
            checkedAt: Date()
        )
    }

    private static func validateTorBox(
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> StremioDebridAccountStatus {
        let url = URL(string: "https://api.torbox.app/v1/api/user/me")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let response = try await client.data(for: request)
        let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
        let dataObj = json["data"] as? [String: Any] ?? json
        let isPremium = (dataObj["premium"] as? Bool)
            ?? ((dataObj["plan"] as? String).map { !$0.lowercased().contains("free") } ?? false)
        return StremioDebridAccountStatus(
            username: dataObj["email"] as? String ?? dataObj["user"] as? String,
            email: dataObj["email"] as? String,
            premiumDays: nil,
            isPremium: isPremium,
            points: nil,
            detail: isPremium ? nil : "Free or unknown plan",
            checkedAt: Date()
        )
    }
}

/// Remembers the last successful binge group per show for next-episode continuity.
enum StremioBingeContinuityStore {
    private static let prefix = "stremio.binge.group."

    static func preferredGroup(forShowID showID: String) -> String? {
        let key = prefix + showID
        return UserDefaults.standard.string(forKey: key)
    }

    static func remember(group: String?, forShowID showID: String, addonID: String?) {
        guard let group, !group.isEmpty else { return }
        UserDefaults.standard.set(group, forKey: prefix + showID)
        if let addonID {
            UserDefaults.standard.set(addonID, forKey: prefix + showID + ".addon")
        }
    }

    static func preferredAddon(forShowID showID: String) -> String? {
        UserDefaults.standard.string(forKey: prefix + showID + ".addon")
    }
}

@MainActor
final class StremioDebridStore: ObservableObject {
    static let shared = StremioDebridStore()

    nonisolated(unsafe) static let preferredServiceKey = "stremio.debrid.preferredService.v1"
    nonisolated(unsafe) static let adultCatalogsKey = "stremio.catalogs.adultOptIn.v1"
    nonisolated(unsafe) static let streamTimeoutKey = "stremio.stream.queryTimeout.v1"
    nonisolated(unsafe) static let maxParallelKey = "stremio.stream.maxParallel.v1"
    static let preferCachedKey = "stremio.stream.preferCached.v1"
    static let maxSizeGBKey = "stremio.stream.maxPreferredSizeGB.v1"
    static let preferSeedersKey = "stremio.stream.preferHealthySeeders.v1"
    static let installCachedOnlyKey = "stremio.debrid.install.cachedOnly.v1"
    static let installQualitiesKey = "stremio.debrid.install.qualities.v1"
    nonisolated(unsafe) static let directUnrestrictKey = "stremio.debrid.directUnrestrict.v1"
    private static let keychainService = "com.betterstreamflix.ios.stremio.debrid"

    @Published private(set) var profiles: [StremioDebridProfile] = []
    @Published private(set) var accountStatuses: [StremioDebridService: StremioDebridAccountStatus] = [:]
    @Published private(set) var isValidating = false
    @Published var preferredService: StremioDebridService {
        didSet {
            UserDefaults.standard.set(preferredService.rawValue, forKey: Self.preferredServiceKey)
        }
    }

    /// When torrents lack HTTP, attempt provider-side magnet unrestrict via the preferred Debrid API.
    var directMagnetUnrestrictEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.directUnrestrictKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.directUnrestrictKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.directUnrestrictKey)
            objectWillChange.send()
        }
    }

    var adultCatalogsOptIn: Bool {
        get { UserDefaults.standard.bool(forKey: Self.adultCatalogsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.adultCatalogsKey)
            objectWillChange.send()
        }
    }

    /// Prefer `[RD+]` / cached debrid HTTP links when ranking sources.
    var preferCachedDebridLinks: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.preferCachedKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.preferCachedKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.preferCachedKey)
            objectWillChange.send()
        }
    }

    /// Soft size preference in GB (0 = no cap).
    var maxPreferredSizeGB: Int {
        get { UserDefaults.standard.integer(forKey: Self.maxSizeGBKey) }
        set {
            UserDefaults.standard.set(max(0, min(100, newValue)), forKey: Self.maxSizeGBKey)
            objectWillChange.send()
        }
    }

    /// Soft-boost streams that advertise healthier seeder counts.
    var preferHealthySeeders: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.preferSeedersKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.preferSeedersKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.preferSeedersKey)
            objectWillChange.send()
        }
    }

    var installCachedOnly: Bool {
        get { UserDefaults.standard.bool(forKey: Self.installCachedOnlyKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.installCachedOnlyKey)
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

    var installOptions: StremioDebridInstallOptions {
        var options = StremioDebridInstallOptions.default
        options.cachedOnly = installCachedOnly
        options.maxSizeGB = maxPreferredSizeGB
        if let raw = UserDefaults.standard.string(forKey: Self.installQualitiesKey), !raw.isEmpty {
            options.qualities = raw.split(separator: ",").map(String.init)
        }
        return options
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
            accountStatuses.removeValue(forKey: service)
        } else {
            Self.saveToken(cleaned, service: service)
        }
        reload()
    }

    func clearAll() {
        for service in StremioDebridService.allCases {
            Self.deleteToken(service: service)
        }
        accountStatuses = [:]
        reload()
    }

    func configuredManifestURL(for curated: StremioCuratedAddon) -> URL? {
        guard let profile = preferredProfile else { return nil }
        return StremioDebridURLBuilder.configuredManifestURL(
            for: curated.id,
            service: profile.service,
            token: profile.token,
            baseManifestURL: curated.manifestURL,
            options: installOptions
        )
    }

    @discardableResult
    func validate(service: StremioDebridService) async -> StremioDebridAccountStatus {
        let token = profiles.first(where: { $0.service == service })?.token ?? ""
        isValidating = true
        defer { isValidating = false }
        let status = await StremioDebridAccountClient.validate(service: service, token: token)
        accountStatuses[service] = status
        return status
    }

    func validatePreferred() async -> StremioDebridAccountStatus? {
        guard let profile = preferredProfile else { return nil }
        return await validate(service: profile.service)
    }

    func applyFastCachedInstallPreset() {
        installCachedOnly = true
        maxPreferredSizeGB = 8
        UserDefaults.standard.set("1080p,720p", forKey: Self.installQualitiesKey)
        objectWillChange.send()
    }

    func applyQualityInstallPreset() {
        installCachedOnly = false
        maxPreferredSizeGB = 0
        UserDefaults.standard.set("4k,1080p,720p", forKey: Self.installQualitiesKey)
        objectWillChange.send()
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

/// Per-addon resolve progress for the player HUD.
struct StremioAddonResolveProgress: Sendable, Hashable, Identifiable {
    var id: String { addonID }
    var addonID: String
    var addonName: String
    var status: Status
    var playable: Int
    var skippedTorrent: Int
    var latencyMS: Int?

    enum Status: String, Sendable, Hashable {
        case pending
        case running
        case ok
        case empty
        case failed
        case skippedConfig
    }

    var chipTitle: String {
        switch status {
        case .pending: "\(addonName)…"
        case .running: "\(addonName)…"
        case .ok: "\(addonName) ✓ \(playable)"
        case .empty: "\(addonName) · 0"
        case .failed: "\(addonName) ✕"
        case .skippedConfig: "\(addonName) cfg"
        }
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
    var sampleExternalURLs: [URL] = []
    var sampleYouTubeIDs: [String] = []
    var perAddon: [StremioAddonResolveProgress] = []
    var continuingBingeGroup: String? = nil

    var primaryExternalURL: URL? { sampleExternalURLs.first }
    var primaryYouTubeURL: URL? {
        guard let id = sampleYouTubeIDs.first else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    var userFacingSummary: String {
        if missingIMDb && !usedTMDbIdentifier {
            return "Stremio needs an IMDb or TMDB id for this title. Open details again after metadata loads, or install a meta addon."
        }
        if queriedAddons == 0 {
            return "No enabled Stremio stream addons. Install Torrentio/Comet with Debrid, or another HTTP stream addon."
        }
        if playableHTTP == 0, skippedTorrent > 0, debridConfigured {
            return "Addons returned \(skippedTorrent) torrent-only result\(skippedTorrent == 1 ? "" : "s") even with Debrid configured. Validate your token under Stremio → Debrid, then Rebind stream addons — the token may be invalid or expired."
        }
        if playableHTTP == 0, skippedTorrent > 0, !debridConfigured {
            return "Addons returned \(skippedTorrent) torrent-only result\(skippedTorrent == 1 ? "" : "s"). Configure Real-Debrid (or another debrid) under Stremio → Debrid, then install Torrentio with your token — BetterStreamflix does not run BitTorrent in-app."
        }
        if playableHTTP == 0, skippedNeedsConfig > 0 {
            return "\(skippedNeedsConfig) addon\(skippedNeedsConfig == 1 ? "" : "s") need configuration. Open Manage plugins and finish setup."
        }
        if playableHTTP == 0, skippedExternal > 0, skippedTorrent == 0 {
            return "Addons only offered external store links. Use Open in Safari below, or install an HTTP/debrid stream addon."
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
        var summary = "\(playableHTTP) playable Stremio stream\(playableHTTP == 1 ? "" : "s")."
        if let group = continuingBingeGroup {
            summary += " Continuing \(group)."
        }
        return summary
    }
}

enum StremioResolveDiagnosticsStore {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var latest = StremioResolveDiagnostics()

    static func update(_ value: StremioResolveDiagnostics) {
        lock.withLock { latest = value }
    }

    static func current() -> StremioResolveDiagnostics {
        lock.withLock { latest }
    }

    static func publishProgress(_ progress: [StremioAddonResolveProgress]) {
        lock.withLock {
            latest.perAddon = progress
        }
    }
}
