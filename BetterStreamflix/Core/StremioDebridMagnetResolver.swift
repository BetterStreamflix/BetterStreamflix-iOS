import Foundation
import UserNotifications

/// Resolves torrent `infoHash` streams into HTTP via the user's Debrid API (still no in-app BitTorrent).
enum StremioDebridMagnetResolver {
    static func resolveHTTPURL(
        infoHash: String,
        fileIdx: Int?,
        service: StremioDebridService,
        token: String,
        client: any HTTPClientProtocol = HTTPClient()
    ) async throws -> URL {
        await MainActor.run {
            StremioUnrestrictStatusStore.shared.begin(service: service)
        }
        defer {
            Task { @MainActor in
                StremioUnrestrictStatusStore.shared.clear()
            }
        }
        let cleanedHash = infoHash
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"^urn:btih:"#, with: "", options: .regularExpression)
        guard cleanedHash.range(of: #"^[a-f0-9]{40}$"#, options: .regularExpression) != nil
            || cleanedHash.range(of: #"^[a-z2-7]{32}$"#, options: .regularExpression) != nil else {
            throw AppError.decoding("Invalid torrent infoHash")
        }
        let magnet = "magnet:?xt=urn:btih:\(cleanedHash)"
        switch service {
        case .realDebrid:
            return try await realDebridUnrestrict(
                magnet: magnet,
                infoHash: cleanedHash,
                fileIdx: fileIdx,
                token: token,
                client: client
            )
        case .allDebrid:
            return try await allDebridUnrestrict(
                magnet: magnet,
                fileIdx: fileIdx,
                token: token,
                client: client
            )
        case .torbox:
            return try await torboxUnrestrict(
                magnet: magnet,
                fileIdx: fileIdx,
                token: token,
                client: client
            )
        case .premiumize:
            return try await premiumizeUnrestrict(
                magnet: magnet,
                fileIdx: fileIdx,
                token: token,
                client: client
            )
        }
    }

    // MARK: - Real-Debrid

    private static func realDebridUnrestrict(
        magnet: String,
        infoHash: String,
        fileIdx: Int?,
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> URL {
        // Instant-availability preflight (best-effort) — still addMagnet when needed.
        if let instant = try? await realDebridInstantLink(
            infoHash: infoHash,
            fileIdx: fileIdx,
            token: token,
            client: client
        ) {
            return instant
        }

        var add = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/addMagnet")!)
        add.httpMethod = "POST"
        add.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        add.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        add.httpBody = "magnet=\(magnet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? magnet)"
            .data(using: .utf8)
        let addJSON = try await json(client.data(for: add).data)
        guard let torrentID = addJSON["id"] as? String else {
            throw AppError.providerUnavailable("Real-Debrid did not accept the magnet")
        }

        var select = URLRequest(
            url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/selectFiles/\(torrentID)")!
        )
        select.httpMethod = "POST"
        select.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        select.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let filesValue: String
        if let fileIdx {
            filesValue = "\(fileIdx + 1)" // RD file ids are 1-based
        } else {
            filesValue = "all"
        }
        select.httpBody = "files=\(filesValue)".data(using: .utf8)
        _ = try? await client.data(for: select)

        var link: String?
        for _ in 0..<10 {
            var infoReq = URLRequest(
                url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/info/\(torrentID)")!
            )
            infoReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let info = try await json(client.data(for: infoReq).data)
            let status = (info["status"] as? String)?.lowercased() ?? ""
            if let links = info["links"] as? [String], !links.isEmpty {
                let idx = min(max(fileIdx ?? 0, 0), links.count - 1)
                link = links[idx]
                break
            }
            if ["error", "virus", "dead"].contains(status) {
                throw AppError.providerUnavailable("Real-Debrid torrent \(status)")
            }
            try await Task.sleep(for: .milliseconds(700))
        }
        guard let link else {
            throw AppError.providerUnavailable("Real-Debrid is still downloading — try a cached source")
        }
        return try await realDebridUnrestrictLink(link, token: token, client: client)
    }

    private static func realDebridInstantLink(
        infoHash: String,
        fileIdx: Int?,
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> URL? {
        // Prefer an already-downloaded torrent in the user's RD library (instant).
        if let existing = try? await realDebridExistingTorrentLink(
            infoHash: infoHash,
            fileIdx: fileIdx,
            token: token,
            client: client
        ) {
            return existing
        }

        var req = URLRequest(
            url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/instantAvailability/\(infoHash)")!
        )
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Instant-availability is advisory only — presence means addMagnet should
        // resolve quickly; we still fall through to the normal path.
        _ = try? await client.data(for: req)
        return nil
    }

    /// Scan RD torrent library for a matching hash that already has unrestricted links.
    private static func realDebridExistingTorrentLink(
        infoHash: String,
        fileIdx: Int?,
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> URL? {
        var req = URLRequest(
            url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents?limit=100")!
        )
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data = try await client.data(for: req).data
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let needle = infoHash.lowercased()
        guard let match = rows.first(where: {
            (($0["hash"] as? String) ?? "").lowercased() == needle
                && (($0["status"] as? String)?.lowercased() == "downloaded"
                    || ($0["status"] as? String)?.lowercased() == "uploading")
        }) else { return nil }
        guard let torrentID = match["id"] as? String else { return nil }

        var infoReq = URLRequest(
            url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/info/\(torrentID)")!
        )
        infoReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let info = try await json(client.data(for: infoReq).data)
        guard let links = info["links"] as? [String], !links.isEmpty else { return nil }
        let idx = min(max(fileIdx ?? 0, 0), links.count - 1)
        return try await realDebridUnrestrictLink(links[idx], token: token, client: client)
    }

    private static func realDebridUnrestrictLink(
        _ link: String,
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> URL {
        var unrestrict = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/unrestrict/link")!)
        unrestrict.httpMethod = "POST"
        unrestrict.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        unrestrict.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        unrestrict.httpBody = "link=\(link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link)"
            .data(using: .utf8)
        let unrestricted = try await json(client.data(for: unrestrict).data)
        guard let download = unrestricted["download"] as? String,
              let url = URL(string: download) else {
            throw AppError.providerUnavailable("Real-Debrid unrestrict failed")
        }
        return url
    }

    // MARK: - AllDebrid

    private static func allDebridUnrestrict(
        magnet: String,
        fileIdx: Int?,
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> URL {
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        let encodedMagnet = magnet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? magnet
        let uploadURL = URL(
            string: "https://api.alldebrid.com/v4/magnet/upload?agent=BetterStreamflix&apikey=\(encodedToken)&magnets[]=\(encodedMagnet)"
        )!
        let upload = try await json(client.data(for: URLRequest(url: uploadURL)).data)
        if let status = (upload["status"] as? String)?.lowercased(), status == "error" {
            let message = (upload["error"] as? [String: Any])?["message"] as? String
                ?? "AllDebrid magnet upload failed"
            throw AppError.providerUnavailable(message)
        }
        let data = upload["data"] as? [String: Any]
        let magnets = data?["magnets"] as? [[String: Any]]
        guard let magnetID = magnets?.first?["id"] as? Int
            ?? (magnets?.first?["id"] as? String).flatMap(Int.init) else {
            throw AppError.providerUnavailable("AllDebrid magnet upload failed")
        }
        let statusURL = URL(
            string: "https://api.alldebrid.com/v4/magnet/status?agent=BetterStreamflix&apikey=\(encodedToken)&id=\(magnetID)"
        )!
        var link: String?
        for _ in 0..<10 {
            let status = try await json(client.data(for: URLRequest(url: statusURL)).data)
            if let apiStatus = (status["status"] as? String)?.lowercased(), apiStatus == "error" {
                let message = (status["error"] as? [String: Any])?["message"] as? String
                    ?? "AllDebrid magnet failed"
                throw AppError.providerUnavailable(message)
            }
            let magnetObj = (status["data"] as? [String: Any])?["magnets"] as? [String: Any]
                ?? status["data"] as? [String: Any]
            let magnetStatus = ((magnetObj?["status"] as? String)
                ?? (magnetObj?["statusCode"] as? Int).map(String.init)
                ?? "").lowercased()
            if ["error", "magnet_error", "file_7"].contains(magnetStatus)
                || magnetStatus.contains("error") {
                throw AppError.providerUnavailable("AllDebrid magnet \(magnetStatus)")
            }
            if let links = magnetObj?["links"] as? [[String: Any]], !links.isEmpty {
                let idx = min(max(fileIdx ?? 0, 0), links.count - 1)
                link = links[idx]["link"] as? String
                if link != nil { break }
            }
            if ["ready", "cached"].contains(magnetStatus), link == nil {
                // Keep polling briefly for link materialization.
            }
            try await Task.sleep(for: .milliseconds(700))
        }
        guard let link else {
            throw AppError.providerUnavailable("AllDebrid is still processing — try a cached source")
        }
        let unlockURL = URL(
            string: "https://api.alldebrid.com/v4/link/unlock?agent=BetterStreamflix&apikey=\(encodedToken)&link=\(link.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? link)"
        )!
        let unlocked = try await json(client.data(for: URLRequest(url: unlockURL)).data)
        let unlockData = unlocked["data"] as? [String: Any]
        guard let download = unlockData?["link"] as? String,
              let url = URL(string: download) else {
            throw AppError.providerUnavailable("AllDebrid unlock failed")
        }
        return url
    }

    // MARK: - TorBox

    private static func torboxUnrestrict(
        magnet: String,
        fileIdx: Int?,
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> URL {
        var create = URLRequest(url: URL(string: "https://api.torbox.app/v1/api/torrents/createtorrent")!)
        create.httpMethod = "POST"
        create.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: [
            "magnet": magnet,
            "seed": 1,
            "allow_zip": false,
        ])
        let created = try await json(client.data(for: create).data)
        let data = created["data"] as? [String: Any]
        guard let torrentID = data?["torrent_id"] as? Int
            ?? (data?["torrent_id"] as? String).flatMap(Int.init) else {
            throw AppError.providerUnavailable("TorBox create failed")
        }

        // Poll briefly until the torrent is downloadable.
        for _ in 0..<8 {
            var infoReq = URLRequest(
                url: URL(string: "https://api.torbox.app/v1/api/torrents/mylist?id=\(torrentID)")!
            )
            infoReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let info = try? await json(client.data(for: infoReq).data) {
                let row = (info["data"] as? [[String: Any]])?.first
                    ?? info["data"] as? [String: Any]
                let downloadState = (row?["download_state"] as? String)?.lowercased()
                    ?? (row?["downloadState"] as? String)?.lowercased()
                    ?? ""
                let progress = (row?["progress"] as? Double) ?? (row?["progress"] as? Int).map(Double.init) ?? 0
                if downloadState.contains("failed") || downloadState.contains("error") {
                    throw AppError.providerUnavailable("TorBox torrent \(downloadState)")
                }
                if downloadState.contains("cached")
                    || downloadState.contains("completed")
                    || downloadState.contains("ready")
                    || progress >= 1 {
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(600))
        }

        var reqLink = URLRequest(
            url: URL(
                string: "https://api.torbox.app/v1/api/torrents/requestdl?token=\(token)&torrent_id=\(torrentID)&file_id=\(fileIdx ?? 0)&redirect=false"
            )!
        )
        reqLink.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let linkJSON = try await json(client.data(for: reqLink).data)
        if let download = linkJSON["data"] as? String, let url = URL(string: download) {
            return url
        }
        if let download = (linkJSON["data"] as? [String: Any])?["url"] as? String,
           let url = URL(string: download) {
            return url
        }
        throw AppError.providerUnavailable("TorBox download link unavailable — try a cached source")
    }

    // MARK: - Premiumize

    private static func premiumizeUnrestrict(
        magnet: String,
        fileIdx: Int?,
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> URL {
        let encoded = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        var request = URLRequest(
            url: URL(string: "https://www.premiumize.me/api/transfer/directdl?apikey=\(encoded)")!
        )
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "src=\(magnet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? magnet)"
            .data(using: .utf8)
        let json = try await json(client.data(for: request).data)
        if let content = json["content"] as? [[String: Any]], !content.isEmpty {
            let idx = min(max(fileIdx ?? preferredVideoIndex(in: content), 0), content.count - 1)
            if let link = content[idx]["link"] as? String, let url = URL(string: link) {
                return url
            }
            if let link = content[idx]["stream_link"] as? String, let url = URL(string: link) {
                return url
            }
        }
        if let location = json["location"] as? String, let url = URL(string: location) {
            return url
        }
        throw AppError.providerUnavailable("Premiumize directdl failed")
    }

    private static func preferredVideoIndex(in content: [[String: Any]]) -> Int {
        let videoExt = ["mkv", "mp4", "avi", "m4v", "mov", "ts", "m2ts"]
        var bestIndex = 0
        var bestSize: Int64 = -1
        for (index, item) in content.enumerated() {
            let path = ((item["path"] as? String) ?? (item["name"] as? String) ?? "").lowercased()
            let size = (item["size"] as? Int64)
                ?? (item["size"] as? Int).map(Int64.init)
                ?? 0
            let looksVideo = videoExt.contains { path.hasSuffix(".\($0)") } || path.contains(".")
            if looksVideo, size >= bestSize {
                bestSize = size
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func json(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.decoding("Unexpected Debrid response")
        }
        return object
    }
}

/// Short-lived in-memory cache of resolved Stremio candidates for the same episode reopen.
actor StremioStreamSessionCache {
    static let shared = StremioStreamSessionCache()

    private struct Entry {
        let candidates: [PlaybackCandidate]
        let storedAt: Date
    }

    private var memory: [String: Entry] = [:]
    private let ttl: TimeInterval = 90

    func candidates(for key: String) -> [PlaybackCandidate]? {
        guard let entry = memory[key], Date().timeIntervalSince(entry.storedAt) < ttl else {
            memory[key] = nil
            return nil
        }
        return entry.candidates
    }

    func store(_ candidates: [PlaybackCandidate], for key: String) {
        memory[key] = Entry(candidates: candidates, storedAt: Date())
    }

    func clear() {
        memory.removeAll()
    }

    static func cacheKey(for context: PlaybackLookupContext) -> String {
        let media = context.request.media
        let episode = context.request.episode.map { "\($0.seasonNumber):\($0.number)" } ?? "movie"
        let debrid = debridFingerprint()
        let addons = addonFingerprint()
        return "\(media.imdbID ?? media.id)|\(episode)|\(media.tmdbID.map(String.init) ?? "")|\(debrid)|\(addons)"
    }

    private static func debridFingerprint() -> String {
        let preferred = UserDefaults.standard.string(forKey: StremioDebridStore.preferredServiceKey) ?? "rd"
        let direct: String
        if UserDefaults.standard.object(forKey: StremioDebridStore.directUnrestrictKey) == nil {
            direct = "1"
        } else {
            direct = UserDefaults.standard.bool(forKey: StremioDebridStore.directUnrestrictKey) ? "1" : "0"
        }
        // Presence of any stored token (not the secret itself) so rebind/token save invalidates cache.
        let services = StremioDebridService.allCases.filter { service in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.betterstreamflix.ios.stremio.debrid",
                kSecAttrAccount as String: "debrid.\(service.rawValue)",
                kSecReturnData as String: false,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }.map(\.rawValue).sorted().joined(separator: ",")
        return "\(preferred)|\(direct)|\(services)"
    }

    private static func addonFingerprint() -> String {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: StremioAddonStore.storageKey),
              let decoded = try? JSONDecoder().decode([InstalledStremioAddon].self, from: data) else {
            return "none"
        }
        return decoded
            .filter(\.isEnabled)
            .filter(\.supportsStream)
            .map { "\($0.id):\($0.manifestURL.absoluteString)" }
            .sorted()
            .joined(separator: ";")
            .hashValue
            .description
    }
}

/// Pinned Stremio catalog shelves (addonID:catalogType:catalogID).
enum StremioFavoriteCatalogsStore {
    private static let key = "stremio.catalogs.favorites.v1"

    static var favorites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }

    static func isFavorite(_ id: String) -> Bool {
        favorites.contains(id)
    }

    static func toggle(_ id: String) {
        var set = favorites
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        favorites = set
    }
}

/// Live status while Debrid magnet→HTTP resolve is in flight.
@MainActor
final class StremioUnrestrictStatusStore: ObservableObject {
    static let shared = StremioUnrestrictStatusStore()
    @Published private(set) var message: String?

    func begin(service: StremioDebridService) {
        message = "Unrestricting via \(service.title)…"
    }

    func clear() {
        message = nil
    }
}

/// Schedules a one-shot local notification when Debrid premium is near expiry.
enum StremioPremiumExpiryNotifier {
    private static let keyPrefix = "stremio.debrid.expiryNotified."

    static func notifyIfNeeded(service: StremioDebridService, status: StremioDebridAccountStatus) {
        guard status.isPremium, let days = status.premiumDays, days <= 5 else { return }
        let key = keyPrefix + service.rawValue + ".\(days)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                    cont.resume(returning: ok)
                }
            }
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(service.title) premium"
            content.body = days == 0
                ? "Your \(service.title) premium ends today — renew to keep Debrid streams."
                : "Your \(service.title) premium has \(days) day\(days == 1 ? "" : "s") left."
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
            let request = UNNotificationRequest(
                identifier: "stremio.debrid.expiry.\(service.rawValue)",
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }
    }
}

/// Foreground health sweep — at most once per 6 hours.
enum StremioForegroundHealthSweep {
    private static let key = "stremio.health.lastForegroundSweep.v1"
    private static let interval: TimeInterval = 6 * 60 * 60

    @MainActor
    static func runIfNeeded(store: StremioAddonStore = .shared) async {
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= interval else { return }
        UserDefaults.standard.set(Date(), forKey: key)
        await store.refreshEnabledStreamHealth()
    }
}

/// Persisted player source-filter defaults.
enum StremioSourceSortMode: String, CaseIterable, Identifiable, Codable {
    case bestMatch
    case quality
    case size
    case seeders
    case cached

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bestMatch: "Best match"
        case .quality: "Quality"
        case .size: "Size"
        case .seeders: "Seeders"
        case .cached: "Cached first"
        }
    }
}

enum StremioSourceFilterPreferences {
    private static let cachedKey = "stremio.sourceFilter.cachedOnly.v1"
    private static let heightKey = "stremio.sourceFilter.minHeight.v1"
    private static let addonKey = "stremio.sourceFilter.addonID.v1"
    private static let sortKey = "stremio.sourceFilter.sortMode.v1"

    static var cachedOnly: Bool {
        get { UserDefaults.standard.bool(forKey: cachedKey) }
        set { UserDefaults.standard.set(newValue, forKey: cachedKey) }
    }

    static var minHeight: Int {
        get { UserDefaults.standard.integer(forKey: heightKey) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: heightKey) }
    }

    static var addonID: String? {
        get {
            let value = UserDefaults.standard.string(forKey: addonKey)
            return (value?.isEmpty == false) ? value : nil
        }
        set { UserDefaults.standard.set(newValue, forKey: addonKey) }
    }

    static var sortMode: StremioSourceSortMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: sortKey),
               let mode = StremioSourceSortMode(rawValue: raw) {
                return mode
            }
            return .bestMatch
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sortKey) }
    }
}

/// Token-free Stremio profile prefs for share / import (addons + ranking, never Keychain tokens).
enum StremioProfileExport {
    struct Payload: Codable {
        var preferredService: String?
        var preferCached: Bool?
        var preferHealthySeeders: Bool?
        var maxSizeGB: Int?
        var streamTimeout: Double?
        var maxParallel: Int?
        var adultOptIn: Bool?
        var installCachedOnly: Bool?
        var sourceFilterCachedOnly: Bool?
        var sourceFilterMinHeight: Int?
        var sourceFilterSort: String?
        var favoriteCatalogIDs: [String]?
        var addonManifestURLs: [String]?
    }

    @MainActor
    static func exportJSON(
        debrid: StremioDebridStore = .shared,
        store: StremioAddonStore = .shared
    ) throws -> Data {
        let payload = Payload(
            preferredService: debrid.preferredService.rawValue,
            preferCached: debrid.preferCachedDebridLinks,
            preferHealthySeeders: debrid.preferHealthySeeders,
            maxSizeGB: debrid.maxPreferredSizeGB,
            streamTimeout: debrid.streamQueryTimeout,
            maxParallel: debrid.maxParallelStreamQueries,
            adultOptIn: debrid.adultCatalogsOptIn,
            installCachedOnly: debrid.installCachedOnly,
            sourceFilterCachedOnly: StremioSourceFilterPreferences.cachedOnly,
            sourceFilterMinHeight: StremioSourceFilterPreferences.minHeight,
            sourceFilterSort: StremioSourceFilterPreferences.sortMode.rawValue,
            favoriteCatalogIDs: Array(StremioFavoriteCatalogsStore.favorites).sorted(),
            addonManifestURLs: store.addons.map(\.manifestURL.absoluteString)
        )
        return try JSONEncoder().encode(payload)
    }

    @MainActor
    static func importJSON(
        _ data: Data,
        debrid: StremioDebridStore = .shared,
        store: StremioAddonStore = .shared
    ) async throws -> Int {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        if let raw = payload.preferredService,
           let service = StremioDebridService(rawValue: raw) {
            debrid.preferredService = service
        }
        if let preferCached = payload.preferCached {
            debrid.preferCachedDebridLinks = preferCached
        }
        if let preferSeeders = payload.preferHealthySeeders {
            debrid.preferHealthySeeders = preferSeeders
        }
        if let maxSize = payload.maxSizeGB {
            debrid.maxPreferredSizeGB = maxSize
        }
        if let timeout = payload.streamTimeout {
            debrid.streamQueryTimeout = timeout
        }
        if let parallel = payload.maxParallel {
            debrid.maxParallelStreamQueries = parallel
        }
        if let adult = payload.adultOptIn {
            debrid.adultCatalogsOptIn = adult
        }
        if let cachedOnly = payload.installCachedOnly {
            debrid.installCachedOnly = cachedOnly
        }
        if let cached = payload.sourceFilterCachedOnly {
            StremioSourceFilterPreferences.cachedOnly = cached
        }
        if let height = payload.sourceFilterMinHeight {
            StremioSourceFilterPreferences.minHeight = height
        }
        if let sort = payload.sourceFilterSort,
           let mode = StremioSourceSortMode(rawValue: sort) {
            StremioSourceFilterPreferences.sortMode = mode
        }
        if let favorites = payload.favoriteCatalogIDs {
            StremioFavoriteCatalogsStore.favorites = Set(favorites)
        }
        var installed = 0
        for url in payload.addonManifestURLs ?? [] {
            do {
                _ = try await store.install(from: url, curated: false)
                installed += 1
            } catch {
                continue
            }
        }
        return installed
    }
}
