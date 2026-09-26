import Foundation

/// Resolves torrent `infoHash` streams into HTTP via the user's Debrid API (still no in-app BitTorrent).
enum StremioDebridMagnetResolver {
    static func resolveHTTPURL(
        infoHash: String,
        fileIdx: Int?,
        service: StremioDebridService,
        token: String,
        client: any HTTPClientProtocol = HTTPClient()
    ) async throws -> URL {
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
                token: token,
                client: client
            )
        }
    }

    // MARK: - Real-Debrid

    private static func realDebridUnrestrict(
        magnet: String,
        fileIdx: Int?,
        token: String,
        client: any HTTPClientProtocol
    ) async throws -> URL {
        // 1) Add magnet
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

        // 2) Select files
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

        // 3) Poll info for links
        var link: String?
        for _ in 0..<8 {
            var infoReq = URLRequest(
                url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/info/\(torrentID)")!
            )
            infoReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let info = try await json(client.data(for: infoReq).data)
            let status = (info["status"] as? String)?.lowercased() ?? ""
            if let links = info["links"] as? [String], let first = links.first {
                link = first
                break
            }
            if ["error", "virus", "dead"].contains(status) {
                throw AppError.providerUnavailable("Real-Debrid torrent \(status)")
            }
            try await Task.sleep(for: .milliseconds(700))
        }
        guard let link else {
            throw AppError.providerUnavailable("Real-Debrid is still downloading — try again shortly")
        }

        // 4) Unrestrict link
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
        for _ in 0..<8 {
            let status = try await json(client.data(for: URLRequest(url: statusURL)).data)
            let magnetObj = (status["data"] as? [String: Any])?["magnets"] as? [String: Any]
                ?? status["data"] as? [String: Any]
            if let links = magnetObj?["links"] as? [[String: Any]] {
                let idx = min(max(fileIdx ?? 0, 0), max(links.count - 1, 0))
                link = links[idx]["link"] as? String
                if link != nil { break }
            }
            try await Task.sleep(for: .milliseconds(700))
        }
        guard let link else {
            throw AppError.providerUnavailable("AllDebrid is still processing the magnet")
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
        throw AppError.providerUnavailable("TorBox download link unavailable")
    }

    // MARK: - Premiumize

    private static func premiumizeUnrestrict(
        magnet: String,
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
        if let content = json["content"] as? [[String: Any]],
           let link = content.first?["link"] as? String,
           let url = URL(string: link) {
            return url
        }
        if let location = json["location"] as? String, let url = URL(string: location) {
            return url
        }
        throw AppError.providerUnavailable("Premiumize directdl failed")
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
        return "\(media.imdbID ?? media.id)|\(episode)|\(media.tmdbID.map(String.init) ?? "")"
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
