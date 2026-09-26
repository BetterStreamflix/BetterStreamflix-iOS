import Foundation

/// OpenSubtitles legacy REST search (`rest.opensubtitles.org`), matching Android `OpenSubtitles`.
/// Queries primary and secondary preferred languages and ranks results for the player pipeline.
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
            ].compactMap { $0 }.filter { !$0.isEmpty }
        }
    ) {
        self.client = client
        self.baseURL = baseURL
        self.preferredLanguageCodes = preferredLanguageCodes
    }

    func subtitles(for lookup: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        let languages = preferredLanguageCodes()
        let queries: [String] = {
            let codes = Array(
                Set(
                    languages
                        .map { String($0.lowercased().prefix(3)) }
                        .filter { !$0.isEmpty }
                )
            )
            return codes.isEmpty ? ["all"] : codes
        }()

        var combined: [SubtitleSource] = []
        var seen = Set<String>()
        for language in queries {
            let batch = await search(lookup: lookup, languageID: language)
            for subtitle in batch where seen.insert(subtitle.id).inserted {
                combined.append(subtitle)
            }
        }
        return SubtitleRanking.sort(combined)
    }

    private func search(lookup: SubtitleLookupRequest, languageID: String) async -> [SubtitleSource] {
        var segments: [String] = []
        let imdb = lookup.imdbID.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "tt", with: "", options: [.anchored, .caseInsensitive])
        if !imdb.isEmpty { segments.append("imdbid-\(imdb)") }
        if let season = lookup.seasonNumber { segments.append("season-\(season)") }
        if let episode = lookup.episodeNumber { segments.append("episode-\(episode)") }
        segments.append("sublanguageid-\(languageID)")
        guard !segments.isEmpty else { return [] }

        let path = "search/" + segments.joined(separator: "/")
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { return [] }
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

        // Prefer higher download counts when the API surfaces them.
        let ordered = rows.sorted {
            ($0.downloads ?? 0) > ($1.downloads ?? 0)
        }

        var seen = Set<String>()
        return ordered.compactMap { row -> SubtitleSource? in
            guard let link = row.subDownloadLink.flatMap(URL.init(string:)),
                  ["http", "https"].contains(link.scheme?.lowercased() ?? "") else { return nil }
            let fileID = row.idSubtitleFile ?? row.subHash ?? link.absoluteString
            let stableID = "\(id):\(fileID)"
            guard seen.insert(stableID).inserted else { return nil }
            let release = row.movieReleaseName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = row.subFileName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let languageName = SubtitleLanguage.displayName(row.iso639 ?? row.subLanguageID)
            let detail = [release, fileName]
                .compactMap { $0 }
                .first { !$0.isEmpty }
            let hearingImpaired = (row.subHearingImpaired ?? "").lowercased()
            let isHI = hearingImpaired == "1"
                || hearingImpaired == "true"
                || hearingImpaired.hasPrefix("y")
            var tags: [String] = []
            if isHI { tags.append("SDH") }
            if let downloads = row.downloads, downloads > 0 {
                tags.append("↓\(Self.compactCount(downloads))")
            }
            let tagSuffix = tags.isEmpty ? "" : " · " + tags.joined(separator: " · ")
            let label: String
            if let detail, !detail.isEmpty {
                label = "\(languageName) · \(detail)\(tagSuffix)"
            } else {
                label = "\(languageName)\(tagSuffix)"
            }
            return SubtitleSource(
                id: stableID,
                providerID: id,
                providerName: displayName,
                label: label,
                languageCode: row.iso639 ?? row.subLanguageID,
                url: link,
                isDefault: false,
                headers: ["User-Agent": "TemporaryUserAgent"]
            )
        }
    }

    private static func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
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
        let subHearingImpaired: String?
        let subDownloads: String?
        let subRating: String?

        var downloads: Int? {
            if let subDownloads, let value = Int(subDownloads) { return value }
            return nil
        }

        enum CodingKeys: String, CodingKey {
            case idSubtitleFile = "IDSubtitleFile"
            case subFileName = "SubFileName"
            case subHash = "SubHash"
            case subLanguageID = "SubLanguageID"
            case iso639 = "ISO639"
            case languageName = "LanguageName"
            case movieReleaseName = "MovieReleaseName"
            case subDownloadLink = "SubDownloadLink"
            case subHearingImpaired = "SubHearingImpaired"
            case subDownloads = "SubDownloads"
            case subRating = "SubRating"
        }
    }
}
