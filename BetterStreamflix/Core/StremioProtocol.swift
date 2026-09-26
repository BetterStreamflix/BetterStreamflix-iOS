import Foundation

// MARK: - Manifest & resource models

struct StremioManifest: Codable, Hashable, Sendable {
    let id: String
    let name: String
    let version: String?
    let description: String?
    let logo: String?
    let background: String?
    let types: [String]?
    let idPrefixes: [String]?
    let resources: [StremioManifestResource]
    let catalogs: [StremioManifestCatalog]
    let behaviorHints: StremioManifestBehaviorHints?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "unknown"
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        version = try container.decodeIfPresent(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        logo = try container.decodeIfPresent(String.self, forKey: .logo)
        background = try container.decodeIfPresent(String.self, forKey: .background)
        types = try container.decodeIfPresent([String].self, forKey: .types)
        idPrefixes = try container.decodeIfPresent([String].self, forKey: .idPrefixes)
        catalogs = try container.decodeIfPresent([StremioManifestCatalog].self, forKey: .catalogs) ?? []
        behaviorHints = try container.decodeIfPresent(
            StremioManifestBehaviorHints.self,
            forKey: .behaviorHints
        )
        if let strings = try? container.decode([String].self, forKey: .resources) {
            resources = strings.map { StremioManifestResource(name: $0) }
        } else {
            resources = try container.decodeIfPresent(
                [StremioManifestResource].self,
                forKey: .resources
            ) ?? []
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, version, description, logo, background, types, idPrefixes
        case resources, catalogs, behaviorHints
    }

    var supportsCatalog: Bool { resources.contains { $0.name == "catalog" } || !catalogs.isEmpty }
    var supportsMeta: Bool { resources.contains { $0.name == "meta" } }
    var supportsStream: Bool { resources.contains { $0.name == "stream" } }
    var supportsSubtitles: Bool { resources.contains { $0.name == "subtitles" } }

    func resource(_ name: String) -> StremioManifestResource? {
        resources.first { $0.name == name }
    }
}

struct StremioManifestResource: Codable, Hashable, Sendable {
    let name: String
    let types: [String]?
    let idPrefixes: [String]?

    init(name: String, types: [String]? = nil, idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
    }
}

struct StremioManifestCatalog: Codable, Hashable, Sendable, Identifiable {
    let type: String
    let id: String
    let name: String?
    let extra: [StremioCatalogExtra]?
    let extraSupported: [String]?
    let extraRequired: [String]?

    var stableID: String { "\(type):\(id)" }
    var displayName: String { name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? id }

    var supportsSearch: Bool {
        (extra ?? []).contains { $0.name == "search" }
            || (extraSupported ?? []).contains("search")
    }

    var requiresExtras: Bool {
        !(extraRequired ?? []).isEmpty
            || (extra ?? []).contains { ($0.isRequired == true) && $0.name != "skip" && $0.name != "genre" }
    }
}

struct StremioCatalogExtra: Codable, Hashable, Sendable {
    let name: String
    let isRequired: Bool?
    let options: [String]?
}

struct StremioManifestBehaviorHints: Codable, Hashable, Sendable {
    let adult: Bool?
    let p2p: Bool?
    let configurable: Bool?
    let configurationRequired: Bool?
}

// MARK: - Meta / stream / subtitle payloads

struct StremioCatalogPayload: Decodable, Sendable {
    let metas: [StremioMetaPreview]
}

struct StremioMetaPayload: Decodable, Sendable {
    let meta: StremioMetaDetail
}

struct StremioStreamPayload: Decodable, Sendable {
    let streams: [StremioStream]
}

struct StremioSubtitlePayload: Decodable, Sendable {
    let subtitles: [StremioSubtitle]
}

struct StremioMetaPreview: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let type: String?
    let name: String?
    let poster: String?
    let posterShape: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]?
    let runtime: String?
    let imdbID: String?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, posterShape, background, logo, description
        case releaseInfo, imdbRating, genres, runtime
        case imdbID = "imdb_id"
    }

    var displayTitle: String { name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? id }

    func asMediaItem(providerID: String) -> MediaItem {
        let kind: MediaKind = (type == "series" || type == "tv") ? .series : .movie
        let imdb = Self.normalizedIMDb(imdbID) ?? Self.normalizedIMDb(id)
        let tmdb = Self.tmdbID(from: id)
        return MediaItem(
            id: "stremio:\(providerID):\(id)",
            providerID: providerID,
            kind: kind,
            title: displayTitle,
            overview: description,
            releaseDate: releaseInfo,
            rating: Double(imdbRating ?? ""),
            imdbID: imdb,
            tmdbID: tmdb,
            posterURL: URL(string: poster ?? ""),
            backdropURL: URL(string: background ?? ""),
            genres: (genres ?? []).enumerated().map { index, name in
                MediaGenre(id: "\(id)-genre-\(index)", name: name)
            }
        )
    }

    private static func normalizedIMDb(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.range(of: #"^tt\d{7,9}$"#, options: .regularExpression) != nil { return raw }
        if let match = raw.range(of: #"tt\d{7,9}"#, options: .regularExpression) {
            return String(raw[match])
        }
        return nil
    }

    private static func tmdbID(from raw: String) -> Int? {
        if raw.hasPrefix("tmdb:") {
            return Int(raw.dropFirst(5))
        }
        return nil
    }
}

struct StremioMetaDetail: Decodable, Hashable, Sendable {
    let id: String
    let type: String?
    let name: String?
    let poster: String?
    let background: String?
    let logo: String?
    let description: String?
    let releaseInfo: String?
    let imdbRating: String?
    let genres: [String]?
    let runtime: String?
    let imdbID: String?
    let videos: [StremioMetaVideo]?
    let moviedbID: Int?

    enum CodingKeys: String, CodingKey {
        case id, type, name, poster, background, logo, description
        case releaseInfo, imdbRating, genres, runtime, videos
        case imdbID = "imdb_id"
        case moviedbID = "moviedb_id"
    }

    func asMediaItem(providerID: String) -> MediaItem {
        let preview = StremioMetaPreview(
            id: id,
            type: type,
            name: name,
            poster: poster,
            posterShape: nil,
            background: background,
            logo: logo,
            description: description,
            releaseInfo: releaseInfo,
            imdbRating: imdbRating,
            genres: genres,
            runtime: runtime,
            imdbID: imdbID
        )
        let base = preview.asMediaItem(providerID: providerID)
        return MediaItem(
            id: base.id,
            providerID: base.providerID,
            kind: base.kind,
            title: base.title,
            originalTitle: base.originalTitle,
            overview: base.overview,
            releaseDate: base.releaseDate,
            rating: base.rating,
            quality: base.quality,
            runtimeMinutes: base.runtimeMinutes,
            imdbID: base.imdbID,
            tmdbID: base.tmdbID ?? moviedbID,
            posterURL: base.posterURL,
            backdropURL: base.backdropURL,
            genres: base.genres,
            cast: base.cast,
            seasons: seasons
        )
    }

    private var seasons: [MediaSeason] {
        guard let videos, !videos.isEmpty else { return [] }
        let numbers = Set(videos.compactMap(\.season))
        return numbers.sorted().map { number in
            MediaSeason(
                id: "\(id)-s\(number)",
                number: number,
                title: "Season \(number)",
                posterURL: URL(string: poster ?? "")
            )
        }
    }

    func episodes(for season: MediaSeason, show: MediaItem) -> [MediaEpisode] {
        (videos ?? [])
            .filter { ($0.season ?? 0) == season.number }
            .sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
            .map { video in
                MediaEpisode(
                    id: video.id,
                    providerID: show.providerID,
                    showID: show.id,
                    seasonNumber: video.season ?? season.number,
                    number: video.episode ?? 0,
                    title: video.title,
                    overview: video.overview,
                    posterURL: URL(string: video.thumbnail ?? "") ?? show.posterURL,
                    releaseDate: video.released
                )
            }
    }
}

struct StremioMetaVideo: Decodable, Hashable, Sendable {
    let id: String
    let title: String?
    let season: Int?
    let episode: Int?
    let overview: String?
    let thumbnail: String?
    let released: String?
}

struct StremioStream: Decodable, Sendable {
    let name: String?
    let title: String?
    let description: String?
    let url: URL?
    let ytId: String?
    let infoHash: String?
    let externalUrl: URL?
    let behaviorHints: BehaviorHints?

    struct BehaviorHints: Decodable, Sendable {
        let bingeGroup: String?
        let videoSize: Int64?
        let filename: String?
        let notWebReady: Bool?
        let proxyHeaders: ProxyHeaders?
    }

    struct ProxyHeaders: Decodable, Sendable {
        let request: [String: String]?
    }

    var displayLabel: String {
        let candidates = [name, title, description?.split(separator: "\n").first.map(String.init)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.first ?? "Stream"
    }

    var detailText: String {
        let parts = [description, title, name].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.first ?? ""
    }
}

struct StremioSubtitle: Decodable, Sendable {
    let id: String?
    let lang: String?
    let url: URL?
}

// MARK: - Protocol client

struct StremioAddonClient: Sendable {
    let client: any HTTPClientProtocol
    let baseURL: URL

    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL) {
        self.client = client
        self.baseURL = baseURL.stremioNormalizedBase
    }

    static func loadManifest(
        from manifestURL: URL,
        client: any HTTPClientProtocol = HTTPClient()
    ) async throws -> (manifest: StremioManifest, baseURL: URL) {
        let url = manifestURL.stremioEnsuredManifestURL
        let manifest: StremioManifest = try await fetch(StremioManifest.self, from: url, client: client)
        return (manifest, url.deletingLastPathComponent().stremioNormalizedBase)
    }

    func manifest() async throws -> StremioManifest {
        try await load(StremioManifest.self, pathComponents: ["manifest.json"])
    }

    func catalog(
        type: String,
        id: String,
        extras: [String: String] = [:]
    ) async throws -> [StremioMetaPreview] {
        let path = resourcePath(resource: "catalog", type: type, id: id, extras: extras)
        return try await load(StremioCatalogPayload.self, pathComponents: path).metas
    }

    func meta(type: String, id: String) async throws -> StremioMetaDetail {
        try await load(
            StremioMetaPayload.self,
            pathComponents: ["meta", type, id + ".json"]
        ).meta
    }

    func streams(type: String, id: String) async throws -> [StremioStream] {
        try await load(
            StremioStreamPayload.self,
            pathComponents: ["stream", type, id + ".json"]
        ).streams
    }

    func streams(for context: PlaybackLookupContext) async throws -> [StremioStream] {
        guard let identifier = Self.streamIdentifier(for: context) else { return [] }
        let type = context.request.media.kind == .movie ? "movie" : "series"
        return try await streams(type: type, id: identifier)
    }

    func subtitles(type: String, id: String) async throws -> [StremioSubtitle] {
        try await load(
            StremioSubtitlePayload.self,
            pathComponents: ["subtitles", type, id + ".json"]
        ).subtitles
    }

    func subtitles(for request: SubtitleLookupRequest) async throws -> [StremioSubtitle] {
        guard let identifier = Self.subtitleIdentifier(for: request) else { return [] }
        let type = request.kind == .movie ? "movie" : "series"
        return try await subtitles(type: type, id: identifier)
    }

    static func streamIdentifier(for context: PlaybackLookupContext) -> String? {
        guard let imdbID = context.request.media.imdbID,
              imdbID.range(of: #"^tt\d{7,9}$"#, options: .regularExpression) != nil else {
            return nil
        }
        if context.request.media.kind == .series {
            guard let episode = context.request.episode else { return nil }
            return "\(imdbID):\(episode.seasonNumber):\(episode.number)"
        }
        return imdbID
    }

    static func subtitleIdentifier(for request: SubtitleLookupRequest) -> String? {
        guard request.imdbID.range(of: #"^tt\d{7,9}$"#, options: .regularExpression) != nil else {
            return nil
        }
        if request.kind == .series {
            guard let season = request.seasonNumber, let episode = request.episodeNumber else {
                return nil
            }
            return "\(request.imdbID):\(season):\(episode)"
        }
        return request.imdbID
    }

    private func resourcePath(
        resource: String,
        type: String,
        id: String,
        extras: [String: String]
    ) -> [String] {
        if extras.isEmpty {
            return [resource, type, id + ".json"]
        }
        let encoded = extras
            .sorted { $0.key < $1.key }
            .map { key, value in
                let escapedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
                let escapedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
                return "\(escapedKey)=\(escapedValue)"
            }
            .joined(separator: "&")
        return [resource, type, id, encoded + ".json"]
    }

    private func load<T: Decodable>(_ type: T.Type, pathComponents: [String]) async throws -> T {
        var url = baseURL
        for (index, component) in pathComponents.enumerated() {
            let isLast = index == pathComponents.count - 1
            if isLast {
                url = url.appendingPathComponent(component)
            } else {
                url = url.appendingPathComponent(component, isDirectory: true)
            }
        }
        return try await Self.fetch(type, from: url, client: client)
    }

    private static func fetch<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        client: any HTTPClientProtocol
    ) async throws -> T {
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BetterStreamflix-iOS", forHTTPHeaderField: "User-Agent")
        let response = try await client.data(for: request)
        try Task.checkCancellation()
        do {
            return try JSONDecoder().decode(type, from: response.data)
        } catch {
            throw AppError.decoding("Stremio addon response")
        }
    }
}

// MARK: - URL helpers

extension URL {
    var stremioNormalizedBase: URL {
        var value = absoluteString
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return URL(string: value) ?? self
    }

    var stremioEnsuredManifestURL: URL {
        if lastPathComponent.lowercased() == "manifest.json" { return self }
        return appendingPathComponent("manifest.json")
    }

    func deletingQuery() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? self
    }
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum StremioManifestURL {
    /// Accepts https manifests, bare hosts, `stremio://` deep links, and noisy paste text.
    static func parse(_ raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Strip wrapping quotes / angle brackets from shared links.
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
            || (value.hasPrefix("<") && value.hasSuffix(">")) {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Extract the first URL-looking token from a pasted sentence.
        if let match = value.range(
            of: #"(?i)(?:stremio|https?)://[^\s<>\"']+"#,
            options: .regularExpression
        ) {
            value = String(value[match])
        }

        value = value.replacingOccurrences(of: "stremio://", with: "https://", options: [.caseInsensitive])

        // Classic installer form: stremio://addon.url/manifest.json already rewritten.
        if value.lowercased().hasPrefix("https://add/") {
            value = "https://" + value.dropFirst("https://add/".count)
        }

        if !value.contains("://") {
            value = "https://" + value
        }

        // Drop trailing punctuation from messengers.
        while let last = value.last, ".,);]".contains(last) {
            value.removeLast()
        }

        guard var url = URL(string: value) else { return nil }
        if url.path.isEmpty || url.path == "/" {
            url = url.appendingPathComponent("manifest.json")
        } else if url.lastPathComponent.lowercased() != "manifest.json",
                  !url.path.lowercased().contains("/manifest.json") {
            if url.pathExtension.isEmpty {
                url = url.appendingPathComponent("manifest.json")
            }
        }
        return url
    }
}
