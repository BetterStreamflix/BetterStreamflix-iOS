import Foundation

/// Legacy OpenSubtitles REST search (`rest.opensubtitles.org`), matching Android `OpenSubtitles`.
/// Returns direct download URLs; the player loads them via the shared subtitle pipeline.
struct OpenSubtitlesSubtitleProvider: SubtitleProvider {
    let id = "opensubtitles"
    let displayName = "OpenSubtitles"

    private let client: any HTTPClientProtocol
    private let baseURL: URL
    private let preferredLanguageCodes: @Sendable () -> [String]

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        baseURL: URL = URL(string: "https://rest.opensubtitles.org/")!,
        preferredLanguageCodes: @escaping @Sendable () -> [String] = {
            let defaults = UserDefaults.standard
            return [
                defaults.string(forKey: "player.subtitleLanguage.primary"),
                defaults.string(forKey: "player.subtitleLanguage.secondary"),
            ].compactMap { $0 }
        }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.preferredLanguageCodes = preferredLanguageCodes
    }

    func subtitles(for lookup: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        var segments: [String] = []
        let imdb = lookup.imdbID.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "tt", with: "", options: [.anchored, .caseInsensitive])
        if !imdb.isEmpty { segments.append("imdbid-\(imdb)") }
        if let season = lookup.seasonNumber { segments.append("season-\(season)") }
        if let episode = lookup.episodeNumber { segments.append("episode-\(episode)") }
        let langs = preferredLanguageCodes()
            .map { $0.lowercased().prefix(3) }
            .filter { !$0.isEmpty }
        if let primary = langs.first {
            segments.append("sublanguageid-\(primary)")
        } else {
            segments.append("sublanguageid-all")
        }
        guard !segments.isEmpty else { return [] }

        let path = "search/" + segments.joined(separator: "/")
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw AppError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("TemporaryUserAgent", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let response: HTTPResponse
        do {
            response = try await SubtitleResourceRetry.load(request: request, client: client)
        } catch {
            SubtitleDiagnostics.logger.error("OpenSubtitles search failed: \(String(describing: error))")
            return []
        }

        let rows: [Row]
        do {
            rows = try JSONDecoder().decode([Row].self, from: response.data)
        } catch {
            SubtitleDiagnostics.logger.error("OpenSubtitles decode failed")
            return []
        }

        var seen = Set<String>()
        return rows.compactMap { row -> SubtitleSource? in
            guard let link = row.subDownloadLink.flatMap(URL.init(string:)),
                  ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { return nil }
            let fileID = row.idSubtitleFile ?? row.subHash ?? link.absoluteString
            let stableID = "\(id):\(fileID)"
            guard seen.insert(stableID).inserted else { return nil }
            let label = (row.subFileName ?? row.movieReleaseName ?? "OpenSubtitles")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return SubtitleSource(
                id: stableID,
                providerID: id,
                providerName: displayName,
                label: label.isEmpty ? "OpenSubtitles" : label,
                languageCode: row.iso639 ?? row.subLanguageID,
                url: link,
                isDefault: false,
                headers: ["User-Agent": "TemporaryUserAgent"]
            )
        }
    }

    private struct Row: Decodable {
        let idSubtitleFile: String?
        let subFileName: String?
        let subHash: String?
        let subLanguageID: String?
        let iso639: String?
        let languageName: String?
        let movieReleaseName: String?
        let subDownloadLink: String?

        enum CodingKeys: String, CodingKey {
            case idSubtitleFile = "IDSubtitleFile"
            case subFileName = "SubFileName"
            case subHash = "SubHash"
            case subLanguageID = "SubLanguageID"
            case iso639 = "ISO639"
            case languageName = "LanguageName"
            case movieReleaseName = "MovieReleaseName"
            case subDownloadLink = "SubDownloadLink"
        }
    }
}
