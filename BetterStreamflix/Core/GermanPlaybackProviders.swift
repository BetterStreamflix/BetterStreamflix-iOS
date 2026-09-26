import Foundation

/// German-language catalogue providers ported from the BetterStreamflix Android
/// app (Apache-2.0). Every provider looks the requested title up on its own site,
/// walks to the page that lists hoster embeds and hands those embeds to
/// `HosterExtractor`.
///
/// Providers soft-fail: a site that is down, geo-blocked or behind a Cloudflare
/// challenge yields no candidates instead of an error, so one dead mirror never
/// stops playback discovery.

// MARK: - Shared provider surface

/// One hoster embed discovered on a catalogue page.
struct GermanHoster: Sendable {
    let name: String
    let url: URL
    /// Candidate identity when several entries share a page URL — Filmo hands out
    /// opaque payloads rather than links.
    var key: String? = nil
    var referer: URL? = nil
    var audioLanguage: String = "de"
    var subtitleKind: StreamSubtitleKind = .unknown
    /// Set when reaching the file needs provider-specific work at playback time.
    var resolve: (@Sendable () async throws -> PlaybackSource)? = nil

    var identity: String { key ?? url.absoluteString }
}

/// A provider that scrapes a German site. Conformers only implement
/// `hosters(for:)`; kind filtering, candidate construction, de-duplication and
/// soft-failing are shared.
protocol GermanPlaybackProvider: PlaybackProvider {
    var displayName: String { get }
    var baseURL: URL { get }
    var supportsMovies: Bool { get }
    var supportsSeries: Bool { get }

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster]
}

extension GermanPlaybackProvider {
    var supportsMovies: Bool { true }
    var supportsSeries: Bool { true }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        switch context.request.media.kind {
        case .movie: guard supportsMovies else { return [] }
        case .series: guard supportsSeries, context.request.episode != nil else { return [] }
        }

        let found: [GermanHoster]
        do {
            found = try await hosters(for: context)
        } catch where error.isCancellation {
            throw error
        } catch {
            return []
        }

        let providerID = id
        let providerName = displayName
        let fallbackReferer = baseURL
        var seen: Set<String> = []
        return found.compactMap { hoster in
            guard seen.insert(hoster.identity).inserted else { return nil }
            return PlaybackCandidate(
                id: "\(providerID):\(hoster.identity)",
                preference: PlaybackSourcePreference(
                    providerID: providerID,
                    serverName: hoster.name,
                    audioLanguage: hoster.audioLanguage
                ),
                providerName: providerName,
                subtitleKind: hoster.subtitleKind,
                resolve: {
                    if let custom = hoster.resolve { return try await custom() }
                    do {
                        return try await HosterExtractor.resolve(
                            hoster.url,
                            referer: hoster.referer ?? fallbackReferer,
                            serverName: hoster.name
                        )
                    } catch where error.isCancellation {
                        throw error
                    } catch {
                        // Soften meinecloud / firestream flakiness: expand every
                        // alternate wrapper host, then take the first healthy mirror.
                        guard MeinecloudEmbedHelper.isEmbedWrapper(hoster.url) else { throw error }
                        let mirrors = await MeinecloudEmbedHelper.expand(
                            hoster.url,
                            referer: hoster.referer ?? fallbackReferer
                        ).filter { !MeinecloudEmbedHelper.isEmbedWrapper($0.url) }
                        guard !mirrors.isEmpty else { throw error }
                        return try await HosterExtractor.resolveFirst(
                            mirrors,
                            referer: hoster.referer ?? fallbackReferer
                        )
                    }
                }
            )
        }
    }
}

// MARK: - Scraping helpers

enum GermanScrape {
    static let client = HosterHTTP.shared

    static func url(_ base: URL, _ path: String = "", query: [String: String] = [:]) -> URL? {
        let resolved: URL?
        if path.isEmpty {
            resolved = base
        } else if path.hasPrefix("http://") || path.hasPrefix("https://") {
            resolved = URL(string: path)
        } else {
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            resolved = URL(string: relative, relativeTo: base)?.absoluteURL
        }
        guard let resolved else { return nil }
        guard !query.isEmpty, var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return resolved
        }
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url
    }

    static func pathEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    /// The path a hoster redirect landed on, still percent-encoded.
    static func encodedPath(of url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
    }

    /// Search terms to try, most specific first. When a release year is known,
    /// also try `"Title 2026"` so remakes do not lose to the franchise original.
    static func queries(for context: PlaybackLookupContext, limit: Int = 2) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        let year = expectedYear(context)
        for title in context.titles {
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, seen.insert(GermanTitleMatching.normalizeTitle(cleaned)).inserted else { continue }
            result.append(cleaned)
            if let year {
                let withYear = "\(cleaned) \(year)"
                if seen.insert(GermanTitleMatching.normalizeTitle(withYear)).inserted {
                    result.append(withYear)
                }
            }
            if result.count >= max(limit * 2, 4) { break }
        }
        return result
    }

    static func expectedYear(_ context: PlaybackLookupContext) -> Int? {
        if context.request.media.kind == .series, let seasonYear = context.seasonYear { return seasonYear }
        return GermanTitleMatching.year(of: context.request.media)
    }

    static func matches(_ title: String, year: Int? = nil, context: PlaybackLookupContext) -> Bool {
        guard GermanTitleMatching.matches(title, titles: context.titles) else { return false }
        return GermanTitleMatching.matchesYear(year, expected: expectedYear(context))
    }

    /// Ranked page pick: exact year → soft year → never title-only when year is known.
    static func bestPage(
        from candidates: [(url: URL, title: String, year: Int?)],
        context: PlaybackLookupContext,
        preferSeason: Int? = nil
    ) -> URL? {
        let titled = candidates.filter {
            GermanTitleMatching.matches($0.title, titles: context.titles)
        }
        guard !titled.isEmpty else { return nil }

        if let preferSeason {
            let seasonHits = titled.filter {
                GermanTitleMatching.seasonNumber(in: $0.title) == preferSeason
                    && GermanTitleMatching.matchesYear($0.year, expected: expectedYear(context))
            }
            if let exact = seasonHits.first(where: {
                guard let year = $0.year, let expected = expectedYear(context) else { return false }
                return year == expected
            }) {
                return exact.url
            }
            if let close = seasonHits.first { return close.url }
        }

        let expected = expectedYear(context)
        if let expected {
            if let exact = titled.first(where: { $0.year == expected }) {
                return exact.url
            }
            if let close = titled.first(where: {
                guard let year = $0.year else { return false }
                return abs(year - expected) <= 1
            }) {
                return close.url
            }
            // Movie remakes must not fall back to a yearless franchise original.
            // Series search cards often omit year, so allow title-only there.
            if context.request.media.kind == .series {
                return titled.first?.url
            }
            return nil
        }
        return titled.first?.url
    }

    /// JSON numbers arrive as `NSNumber`, so ids need coercing before use in a path.
    static func scalar(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as Int: return String(number)
        case let number as Double: return number == number.rounded() ? String(Int(number)) : String(number)
        default: return nil
        }
    }

    static func flag(_ value: Any?) -> Bool {
        if let boolean = value as? Bool { return boolean }
        if let number = value as? Int { return number != 0 }
        return false
    }

    static func text(in html: String) -> String {
        AnimeHTML.parse(html).text
    }

    /// Meinecloud wrappers name the real hoster, so expanding them up front gives
    /// the picker "Voe" and "Mixdrop" rows instead of a single "Meinecloud" row.
    static func expandingWrappers(_ hosters: [GermanHoster], limit: Int = 2) async -> [GermanHoster] {
        var passthrough: [GermanHoster] = []
        var toExpand: [(index: Int, hoster: GermanHoster)] = []
        var expanded = 0
        for (index, hoster) in hosters.enumerated() {
            if MeinecloudEmbedHelper.isEmbedWrapper(hoster.url), expanded < limit {
                toExpand.append((index, hoster))
                expanded += 1
            } else {
                passthrough.append(hoster)
            }
        }
        guard !toExpand.isEmpty else { return hosters }

        var expansions: [Int: [GermanHoster]] = [:]
        await withTaskGroup(of: (Int, [GermanHoster]).self) { group in
            for item in toExpand {
                group.addTask {
                    let mirrors = await MeinecloudEmbedHelper.expand(item.hoster.url, referer: item.hoster.referer)
                        .filter { !MeinecloudEmbedHelper.isEmbedWrapper($0.url) }
                    let mapped = mirrors.isEmpty ? [item.hoster] : mirrors.map { mirror in
                        GermanHoster(
                            name: MeinecloudEmbedHelper.hosterDisplayName(for: mirror.url),
                            url: mirror.url,
                            referer: item.hoster.url,
                            audioLanguage: item.hoster.audioLanguage
                        )
                    }
                    return (item.index, mapped)
                }
            }
            for await (index, mapped) in group {
                expansions[index] = mapped
            }
        }

        var result: [GermanHoster] = []
        for (index, hoster) in hosters.enumerated() {
            if let mapped = expansions[index] {
                result.append(contentsOf: mapped)
            } else {
                result.append(hoster)
            }
        }
        return result
    }

    /// Follows a provider redirect to the hoster it points at, optionally remapping
    /// VOE onto its canonical domain the way the Android providers do.
    static func followRedirect(
        _ link: URL,
        referer: URL,
        serverName: String,
        voePrefix: String? = nil
    ) async throws -> PlaybackSource {
        let response = try await client.get(link, referer: referer)
        var target = response.url
        if let voePrefix, serverName.localizedCaseInsensitiveContains("voe") {
            let path = encodedPath(of: target).drop { $0 == "/" }
            if let remapped = URL(string: voePrefix + path) { target = remapped }
        }
        return try await HosterExtractor.resolve(target, referer: referer, serverName: serverName)
    }
}

// MARK: - Einschalten

/// Movies only: the watch endpoint answers with a single DoodStream share link.
struct EinschaltenPlaybackProvider: GermanPlaybackProvider {
    var id: String { "einschalten" }
    var displayName: String { "Einschalten" }
    var baseURL: URL { Self.base }
    var supportsSeries: Bool { false }

    private static let base = URL(string: "https://einschalten.in/")!

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        guard let tmdbID = context.request.media.tmdbID,
              let watch = GermanScrape.url(baseURL, "api/movies/\(tmdbID)/watch") else { return [] }
        let payload = try await GermanScrape.client.jsonObject(watch, referer: baseURL)
        guard let raw = GermanScrape.scalar(payload["streamUrl"]),
              let stream = URL(string: raw) else { return [] }
        return [GermanHoster(name: "DoodStream", url: stream, referer: baseURL)]
    }
}

// MARK: - Moflix-Stream

/// The catalogue is keyed by TMDB id (`base64("tmdb|movie|603")`), which is far
/// more reliable than the title search; the search endpoint is the fallback.
struct MStreamPlaybackProvider: GermanPlaybackProvider {
    var id: String { "moflix-stream" }
    var displayName: String { "Moflix-Stream" }
    var baseURL: URL { Self.base }

    private static let base = URL(string: "https://moflix-stream.xyz/")!

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        let videos: [[String: Any]]
        if let episode = context.request.episode {
            guard let titleID = try await titleID(for: context) else { return [] }
            guard let url = GermanScrape.url(
                baseURL,
                "api/v1/titles/\(titleID)/seasons/\(episode.seasonNumber)/episodes/\(episode.number)",
                query: ["loader": "episodePage"]
            ) else { return [] }
            videos = Self.videos(in: try await GermanScrape.client.jsonObject(url, referer: baseURL))
        } else {
            videos = try await movieVideos(for: context)
        }

        return videos.compactMap { video in
            guard !GermanScrape.flag(video["premium_locked"]) else { return nil }
            let source = GermanScrape.scalar(video["src"])
            let resolvePath = GermanScrape.scalar(video["playback_resolve_url"])
            let link = source ?? resolvePath.map { baseURL.absoluteString + "api/v1/" + $0 }
            guard let link, let url = URL(string: link) else { return nil }

            let label = GermanScrape.scalar(video["name"]) ?? MeinecloudEmbedHelper.hosterDisplayName(for: url)
            let name = source == nil ? label : "\(MeinecloudEmbedHelper.hosterDisplayName(for: url)) (\(label))"
            guard link.contains("/playback") else {
                return GermanHoster(name: name, url: url, referer: baseURL)
            }
            return GermanHoster(name: name, url: url, referer: baseURL, resolve: {
                try await Self.playbackSource(at: url)
            })
        }
    }

    private func movieVideos(for context: PlaybackLookupContext) async throws -> [[String: Any]] {
        if let tmdbID = context.request.media.tmdbID,
           let url = GermanScrape.url(baseURL, "api/v1/titles/\(Self.tmdbKey(kind: .movie, id: tmdbID))", query: ["loader": "titlePage"]),
           let payload = try? await GermanScrape.client.jsonObject(url, referer: baseURL) {
            let videos = Self.videos(in: payload)
            if !videos.isEmpty { return videos }
        }
        guard let result = try await searchResult(for: context),
              let primary = result["primary_video"] as? [String: Any],
              let watchID = GermanScrape.scalar(primary["id"]),
              let url = GermanScrape.url(baseURL, "api/v1/watch/\(watchID)") else { return [] }
        return Self.videos(in: try await GermanScrape.client.jsonObject(url, referer: baseURL))
    }

    private func titleID(for context: PlaybackLookupContext) async throws -> String? {
        if let tmdbID = context.request.media.tmdbID {
            let key = Self.tmdbKey(kind: .series, id: tmdbID)
            if let url = GermanScrape.url(baseURL, "api/v1/titles/\(key)", query: ["loader": "titlePage"]),
               let payload = try? await GermanScrape.client.jsonObject(url, referer: baseURL),
               let title = payload["title"] as? [String: Any],
               let identifier = GermanScrape.scalar(title["id"]) {
                return identifier
            }
        }
        return try await searchResult(for: context).flatMap { GermanScrape.scalar($0["id"]) }
    }

    private func searchResult(for context: PlaybackLookupContext) async throws -> [String: Any]? {
        let wantsSeries = context.request.media.kind == .series
        for query in GermanScrape.queries(for: context) {
            try Task.checkCancellation()
            guard let url = GermanScrape.url(
                baseURL,
                "api/v1/search/\(GermanScrape.pathEncoded(query))",
                query: ["loader": "searchPage"]
            ) else { continue }
            guard let payload = try? await GermanScrape.client.jsonObject(url, referer: baseURL),
                  let results = payload["results"] as? [[String: Any]] else { continue }

            for result in results {
                let entry = result["title"] as? [String: Any] ?? result
                let isSeries = GermanScrape.flag(result["is_series"]) || GermanScrape.flag(entry["is_series"])
                guard isSeries == wantsSeries else { continue }
                let name = GermanScrape.scalar(entry["name"]) ?? ""
                let year = GermanScrape.scalar(entry["year"]).flatMap(Int.init)
                guard GermanScrape.matches(name, year: year, context: context) else { continue }
                return entry
            }
        }
        return nil
    }

    /// Premium mirrors hide the playlist behind `/videos/{id}/playback`.
    private static func playbackSource(at link: URL) async throws -> PlaybackSource {
        let videoID = link.absoluteString
            .components(separatedBy: "videos/").last?
            .components(separatedBy: "/playback").first ?? ""
        let referer = URL(string: base.absoluteString + "watch/" + videoID) ?? base
        let payload = try await GermanScrape.client.jsonObject(link, referer: referer)
        guard let source = GermanScrape.scalar(payload["src"]), let url = URL(string: source) else {
            throw AppError.noStream
        }
        return PlaybackSource(
            url: url,
            headers: HosterExtractor.headers(referer: referer),
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    private static func tmdbKey(kind: MediaKind, id: Int) -> String {
        Data("tmdb|\(kind == .movie ? "movie" : "series")|\(id)".utf8).base64EncodedString()
    }

    private static func videos(in payload: [String: Any]) -> [[String: Any]] {
        if let list = payload["videos"] as? [[String: Any]] { return list }
        if let list = payload["alternative_videos"] as? [[String: Any]] { return list }
        if let title = payload["title"] as? [String: Any], let list = title["videos"] as? [[String: Any]] { return list }
        if let episode = payload["episode"] as? [String: Any], let list = episode["videos"] as? [[String: Any]] { return list }
        return []
    }
}

// MARK: - Filmpalast

struct FilmPalastPlaybackProvider: GermanPlaybackProvider {
    var id: String { "filmpalast" }
    var displayName: String { "Filmpalast" }
    var baseURL: URL { Self.base }

    private static let base = URL(string: "https://filmpalast.to/")!

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        guard let slug = try await findSlug(for: context) else { return [] }
        guard let page = GermanScrape.url(baseURL, "stream/\(slug)") else { return [] }
        let html = try await GermanScrape.client.page(page, referer: baseURL)

        guard let episode = context.request.episode else { return streamLinks(in: html, page: page) }
        guard let episodeSlug = Self.episodeSlug(
            in: html,
            season: episode.seasonNumber,
            episode: episode.number
        ) else { return streamLinks(in: html, page: page) }
        guard let episodePage = GermanScrape.url(baseURL, "stream/\(episodeSlug)") else { return [] }
        let episodeHTML = try await GermanScrape.client.page(episodePage, referer: page)
        return streamLinks(in: episodeHTML, page: episodePage)
    }

    private func findSlug(for context: PlaybackLookupContext) async throws -> String? {
        var ranked: [(url: URL, title: String, year: Int?)] = []
        var seen = Set<String>()
        for query in GermanScrape.queries(for: context) {
            try Task.checkCancellation()
            guard let search = GermanScrape.url(baseURL, "search/title/\(GermanScrape.pathEncoded(query))"),
                  let html = try? await GermanScrape.client.page(search, referer: baseURL) else { continue }

            for article in AnimeHTML.parse(html).all({ $0.tag == "article" }) {
                let link = article.first { $0.tag == "h2" }?.first { $0.tag == "a" && !$0["href"].isEmpty }
                    ?? article.first { $0.tag == "a" && $0["href"].contains("/stream/") }
                guard let link else { continue }
                let title = link.text.isEmpty ? link["title"] : link.text
                let year = GermanTitleMatching.year(in: article.text) ?? GermanTitleMatching.year(in: title)
                guard GermanTitleMatching.matches(title, titles: context.titles) else { continue }
                let slug = link["href"].components(separatedBy: "/").last ?? ""
                guard !slug.isEmpty, seen.insert(slug).inserted,
                      let placeholder = URL(string: "https://filmpalast.to/\(slug)") else { continue }
                ranked.append((placeholder, title, year))
            }
        }
        return GermanScrape.bestPage(from: ranked, context: context)?.lastPathComponent
    }

    /// Series pages group episodes per season block; both are ordered, not labelled.
    private static func episodeSlug(in html: String, season: Int, episode: Int) -> String? {
        let tree = AnimeHTML.parse(html)
        guard let wrapper = tree.first({ $0["id"] == "staffelWrapper" }) else { return nil }
        let blocks = wrapper.all { $0.hasClass("staffelWrapperLoop") }
        guard season >= 1, season <= blocks.count else { return nil }
        let links = blocks[season - 1].all { $0.tag == "a" && $0.hasClass("getStaffelStream") }
        guard episode >= 1, episode <= links.count else { return nil }
        return links[episode - 1]["href"].components(separatedBy: "/").last
    }

    private func streamLinks(in html: String, page: URL) -> [GermanHoster] {
        AnimeHTML.parse(html).all { $0.tag == "ul" && $0.hasClass("currentStreamLinks") }.compactMap { block in
            let name = block.first { $0.tag == "p" && $0.hasClass("hostName") }?.text ?? "Unbekannt"
            let anchor = block.first { $0.tag == "a" && !$0["href"].isEmpty }
                ?? block.first { $0.tag == "a" && !$0["data-player-url"].isEmpty }
            guard let anchor else { return nil }
            let raw = anchor["href"].isEmpty ? anchor["data-player-url"] : anchor["href"]
            guard let link = MeinecloudEmbedHelper.normalize(raw, relativeTo: page) else { return nil }
            return GermanHoster(name: name, url: link, referer: page, resolve: {
                try await GermanScrape.followRedirect(
                    link,
                    referer: page,
                    serverName: name,
                    voePrefix: "https://voe.sx/e/"
                )
            })
        }
    }
}

// MARK: - Filmo

/// Movies only. Hoster links are opaque payloads that have to be minted through a
/// CSRF-protected endpoint before the site hands out a redirect.
struct FilmoPlaybackProvider: GermanPlaybackProvider {
    var id: String { "filmo" }
    var displayName: String { "Filmo" }
    var baseURL: URL { Self.base }
    var supportsSeries: Bool { false }

    private static let base = URL(string: "https://filmo.to/")!

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        guard let page = try await findMovie(for: context) else { return [] }
        let html = try await GermanScrape.client.page(page, referer: baseURL)

        var seenLinkIDs: Set<String> = []
        return AnimeHTML.parse(html).all({ !$0["data-p"].isEmpty }).compactMap { chip in
            let payload = chip["data-p"].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return nil }
            let linkID = chip["data-movie-link-id"]
            guard linkID.isEmpty || seenLinkIDs.insert(linkID).inserted else { return nil }

            let label = chip["aria-label"].trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = chip.first { $0.hasClass("provider-chip__name") }?.text ?? ""
            let name = [label, fallback, "Server"].first { !$0.isEmpty } ?? "Server"

            return GermanHoster(name: name, url: page, key: payload, referer: page, resolve: {
                try await Self.mintedSource(payload: payload, name: name, page: page)
            })
        }
    }

    private func findMovie(for context: PlaybackLookupContext) async throws -> URL? {
        var ranked: [(url: URL, title: String, year: Int?)] = []
        var seen = Set<URL>()
        for query in GermanScrape.queries(for: context) {
            try Task.checkCancellation()
            guard let suggest = GermanScrape.url(baseURL, "search/suggest", query: ["q": query]),
                  let payload = try? await GermanScrape.client.jsonObject(suggest, referer: baseURL),
                  let movies = payload["movies"] as? [[String: Any]] else { continue }
            for movie in movies {
                guard let title = GermanScrape.scalar(movie["title"]),
                      let raw = GermanScrape.scalar(movie["url"]),
                      GermanTitleMatching.matches(title, titles: context.titles),
                      let url = GermanScrape.url(baseURL, raw),
                      seen.insert(url).inserted else { continue }
                let year = GermanScrape.scalar(movie["year"]).flatMap(Int.init)
                    ?? GermanScrape.scalar(movie["release_year"]).flatMap(Int.init)
                    ?? GermanTitleMatching.year(in: GermanScrape.scalar(movie["release_date"]))
                    ?? GermanTitleMatching.year(in: title)
                ranked.append((url, title, year))
            }
        }
        return GermanScrape.bestPage(from: ranked, context: context)
    }

    /// `POST /n` exchanges the chip payload for a one-shot token; `/n/{token}`
    /// then redirects to the hoster. The CSRF meta tag and the `XSRF-TOKEN`
    /// cookie have to come from the same response, so the session cookies are
    /// replayed by hand rather than trusted to the shared jar.
    private static func mintedSource(payload: String, name: String, page: URL) async throws -> PlaybackSource {
        let home = try await GermanScrape.client.get(base, referer: base)
        let csrf = AnimeHTML.parse(home.text).first { $0.tag == "meta" && $0["name"] == "csrf-token" }?["content"] ?? ""
        let xsrf = home.cookie(named: "XSRF-TOKEN") ?? GermanScrape.client.cookie(named: "XSRF-TOKEN", for: base) ?? ""
        guard !csrf.isEmpty, !xsrf.isEmpty else { throw AppError.providerUnavailable("Filmo session unavailable") }

        var session: [String: String] = ["X-CSRF-TOKEN": csrf, "X-XSRF-TOKEN": xsrf]
        if let cookies = home.cookieHeader { session["Cookie"] = cookies }

        guard let mint = GermanScrape.url(base, "n") else { throw AppError.invalidURL }
        var request = HosterHTTP.jsonRequest(url: mint, referer: base, headers: session, body: ["p": payload])
        request.httpShouldHandleCookies = home.cookieHeader == nil
        let response = try await GermanScrape.client.send(request)
        guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let token = GermanScrape.scalar(object["x"]),
              let tokenURL = GermanScrape.url(base, "n/\(GermanScrape.pathEncoded(token))") else {
            throw AppError.noStream
        }

        var redirectRequest = HosterHTTP.request(url: tokenURL, referer: page)
        if let cookies = home.cookieHeader {
            redirectRequest.setValue(cookies, forHTTPHeaderField: "Cookie")
            redirectRequest.httpShouldHandleCookies = false
        }
        let redirect = try await GermanScrape.client.send(redirectRequest)
        guard redirect.url != tokenURL else { throw AppError.noStream }
        return try await HosterExtractor.resolve(redirect.url, referer: page, serverName: name)
    }
}

// MARK: - HDFilme

/// Prefers the meinecloud embeds keyed by IMDb id; the site's own search is broken,
/// so the title path walks its sitemap instead.
struct HDFilmePlaybackProvider: GermanPlaybackProvider {
    var id: String { "hdfilme" }
    var displayName: String { "HDFilme" }
    var baseURL: URL { Self.base }

    private static let base = URL(string: "https://hdfilme.cafe/")!
    private static let sitemaps = ["news_pages.xml", "news_pages2.xml"]

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        if let imdb = Self.imdbID(context.request.media.imdbID) {
            let hosters = try await embedHosters(imdb: imdb, context: context)
            if !hosters.isEmpty { return hosters }
        }
        guard let page = try await findPage(for: context) else { return [] }
        let html = try await GermanScrape.client.page(page, referer: baseURL)

        if let episode = context.request.episode {
            if let imdb = Self.imdbID(AnimeHTML.captures(#"var\s+imdb\s*=\s*['"](tt\d+)['"]"#, in: html).first?[1]) {
                let hosters = try await embedHosters(imdb: imdb, context: context)
                if !hosters.isEmpty { return hosters }
            }
            return Self.spoilerHosters(in: html, page: page, season: episode.seasonNumber, episode: episode.number)
        }
        return try await Self.embedMirrors(in: html, page: page)
    }

    private func embedHosters(imdb: String, context: PlaybackLookupContext) async throws -> [GermanHoster] {
        guard let episode = context.request.episode else {
            guard let embed = URL(string: "https://meinecloud.click/movie/\(imdb)") else { return [] }
            return await MeinecloudEmbedHelper.expand(embed, referer: baseURL).map {
                GermanHoster(name: $0.name, url: $0.url, referer: embed)
            }
        }
        guard let html = try await serialPage(imdb: imdb),
              let link = Self.serialEpisodeLink(
                  in: html,
                  season: episode.seasonNumber,
                  episode: episode.number
              ) else { return [] }
        return [GermanHoster(name: MeinecloudEmbedHelper.hosterDisplayName(for: link), url: link, referer: baseURL)]
    }

    /// The serial player lives under a numeric path; the check endpoint hands out
    /// the current one when that guess 404s.
    private func serialPage(imdb: String) async throws -> String? {
        let numeric = imdb.hasPrefix("tt") ? String(imdb.dropFirst(2)) : imdb
        if let direct = URL(string: "https://meinecloud.click/serial/\(numeric)"),
           let html = try? await GermanScrape.client.page(direct, referer: baseURL),
           html.contains("_season-eps") {
            return html
        }
        guard let check = URL(string: "https://meinecloud.click/serials.php?task=check&id_imdb=\(imdb)"),
              let body = try? await GermanScrape.client.page(check, referer: baseURL),
              let raw = AnimeHTML.captures(#""player_url"\s*:\s*"([^"]+)""#, in: body).first?[1],
              let player = URL(string: raw.replacingOccurrences(of: "\\/", with: "/")) else { return nil }
        return try? await GermanScrape.client.page(player, referer: baseURL)
    }

    private static func serialEpisodeLink(in html: String, season: Int, episode: Int) -> URL? {
        let tree = AnimeHTML.parse(html)
        let seasons = tree.all { $0.hasClass("_season-eps") }
        let tabs = tree.all { $0.hasClass("_stab") }

        func number(of block: AnimeHTML) -> Int? {
            let identifier = block["data-season"]
            if let tab = tabs.first(where: { $0["data-season"] == identifier }),
               let match = AnimeHTML.captures(#"S(\d+)"#, in: tab.text).first {
                return Int(match[1])
            }
            guard let label = block.first({ $0.hasClass("_ep") && !$0["data-label"].isEmpty })?["data-label"],
                  let match = AnimeHTML.captures(#"S(\d+)\s*E\d+"#, in: label).first else { return nil }
            return Int(match[1])
        }

        guard let block = seasons.first(where: { number(of: $0) == season }) else { return nil }
        let entry = block.all { $0.hasClass("_ep") }.first { node in
            if let value = node.first({ $0.hasClass("_ep-n") })?.text, let parsed = Int(value) { return parsed == episode }
            guard let match = AnimeHTML.captures(#"S\d+\s*E(\d+)"#, in: node["data-label"]).first else { return false }
            return Int(match[1]) == episode
        }
        guard let raw = entry?["data-link"], let decoded = MeinecloudEmbedHelper.decodeDataLink(raw) else { return nil }
        return MeinecloudEmbedHelper.normalize(decoded)
    }

    /// Older show pages list episodes as `<br>`-separated "1x2 Episode 2" lines.
    private static func spoilerHosters(in html: String, page: URL, season: Int, episode: Int) -> [GermanHoster] {
        var result: [GermanHoster] = []
        var seen: Set<URL> = []
        for line in html.components(separatedBy: "<br") {
            guard !AnimeHTML.captures(#"\b\#(season)x\#(episode)\s+Episode\b"#, in: line).isEmpty else { continue }
            for match in AnimeHTML.captures(#"<a[^>]+href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, in: line) {
                let name = HTMLPayloadParser.decodeEntities(match[2])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !match[1].contains("/engine/player.php"),
                      !name.localizedCaseInsensitiveContains("Player HD"),
                      !name.localizedCaseInsensitiveContains("4K"),
                      let url = MeinecloudEmbedHelper.normalize(match[1], relativeTo: page),
                      seen.insert(url).inserted else { continue }
                result.append(GermanHoster(name: name.isEmpty ? "Server" : name, url: url, referer: page))
            }
        }
        return result
    }

    private static func embedMirrors(in html: String, page: URL) async throws -> [GermanHoster] {
        let frames = AnimeHTML.parse(html).all { $0.tag == "iframe" }.compactMap { node -> URL? in
            let raw = node["src"].isEmpty ? node["data-src"] : node["src"]
            guard let url = MeinecloudEmbedHelper.normalize(raw, relativeTo: page),
                  !(url.hostName ?? "").contains("youtu") else { return nil }
            return url
        }
        for frame in frames.prefix(3) {
            try Task.checkCancellation()
            let mirrors = await MeinecloudEmbedHelper.expand(frame, referer: page)
            if !mirrors.isEmpty {
                return mirrors.map { GermanHoster(name: $0.name, url: $0.url, referer: frame) }
            }
        }
        return frames.prefix(1).map { GermanHoster(name: "Embed", url: $0, referer: page) }
    }

    private func findPage(for context: PlaybackLookupContext) async throws -> URL? {
        let wantsSeries = context.request.media.kind == .series
        let entries = await Self.sitemapEntries()
        guard !entries.isEmpty else { return nil }

        for query in GermanScrape.queries(for: context) {
            let tokens = Self.searchTokens(query)
            guard !tokens.isEmpty else { continue }
            let matching = entries.filter { entry in tokens.allSatisfy { entry.slug.contains($0) } }
            for entry in matching.prefix(3) {
                try Task.checkCancellation()
                guard let html = try? await GermanScrape.client.page(entry.url, referer: baseURL) else { continue }
                let isSeries = html.contains("themoviedb.org/tv/") || html.contains("serial_iframe")
                guard isSeries == wantsSeries else { continue }
                return entry.url
            }
        }
        return nil
    }

    private struct SitemapEntry: Sendable {
        let url: URL
        let slug: String
    }

    private static func sitemapEntries() async -> [SitemapEntry] {
        var entries: [SitemapEntry] = []
        var seen: Set<URL> = []
        for name in sitemaps {
            guard let sitemap = GermanScrape.url(base, name),
                  let body = try? await GermanScrape.client.page(sitemap, referer: base) else { continue }
            for match in AnimeHTML.captures(#"<loc>\s*([^<\s]+)\s*</loc>"#, in: body) {
                guard let url = URL(string: match[1]), seen.insert(url).inserted else { continue }
                let encoded = url.absoluteString.components(separatedBy: "/").last ?? ""
                entries.append(SitemapEntry(url: url, slug: (encoded.removingPercentEncoding ?? encoded).lowercased()))
            }
        }
        return entries
    }

    private static func searchTokens(_ value: String) -> [String] {
        value.lowercased()
            .replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-stream(?:ing)?-stream\.html$"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func imdbID(_ raw: String?) -> String? {
        guard let raw, let match = AnimeHTML.captures(#"(tt\d{6,10})"#, in: raw).first else { return nil }
        return match[1]
    }
}

// MARK: - KinoGer

struct KinoGerPlaybackProvider: GermanPlaybackProvider {
    var id: String { "kinoger" }
    var displayName: String { "KinoGer" }
    var baseURL: URL { Self.base }

    private static let base = URL(string: "https://kinoger.fun/")!

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        guard let page = try await findPage(for: context) else {
            return await imdbMeinecloudFallback(for: context)
        }
        let html = try await GermanScrape.client.page(page, referer: baseURL)

        // Reject franchise hijacks when the page exposes a different IMDb id.
        if let expectedIMDb = context.request.media.imdbID?.lowercased(),
           let pageIMDb = AnimeHTML.captures(#"(tt\d{7,8})"#, in: html).first?[1].lowercased(),
           pageIMDb != expectedIMDb {
            return await imdbMeinecloudFallback(for: context)
        }

        let links: [(url: URL, label: String)]
        if let episode = context.request.episode {
            links = Self.episodeLinks(
                in: html,
                page: page,
                season: episode.seasonNumber,
                episode: episode.number
            )
        } else {
            links = Self.movieLinks(in: html, page: page)
        }

        var hosters = links.map { link in
            GermanHoster(
                name: MeinecloudEmbedHelper.hosterDisplayName(for: link.url),
                url: link.url,
                referer: page
            )
        }
        // Expand a couple of wrappers in parallel — full expand-of-all was serial
        // and slower than Android's getServers → play first path.
        hosters = await GermanScrape.expandingWrappers(hosters, limit: 3)
        if !hosters.isEmpty { return hosters }
        return await imdbMeinecloudFallback(for: context, referer: page)
    }

    private func imdbMeinecloudFallback(
        for context: PlaybackLookupContext,
        referer: URL? = nil
    ) async -> [GermanHoster] {
        guard context.request.episode == nil,
              let imdb = context.request.media.imdbID,
              imdb.hasPrefix("tt"),
              let embed = URL(string: "https://meinecloud.click/movie/\(imdb)") else {
            return []
        }
        return await MeinecloudEmbedHelper.expand(embed, referer: referer ?? baseURL).map {
            GermanHoster(name: $0.name, url: $0.url, referer: embed)
        }
    }

    private func findPage(for context: PlaybackLookupContext) async throws -> URL? {
        let season = context.request.episode?.seasonNumber
        var ranked: [(url: URL, title: String, year: Int?)] = []
        var seen = Set<URL>()

        for query in GermanScrape.queries(for: context) {
            try Task.checkCancellation()
            guard let search = GermanScrape.url(baseURL, "", query: [
                "do": "search",
                "subaction": "search",
                "story": query,
            ]), let html = try? await GermanScrape.client.page(search, referer: baseURL) else { continue }

            for card in AnimeHTML.parse(html).all({ $0.tag == "div" && $0.hasClass("short") }) {
                let anchor = card.first { $0.hasClass("title") }?.first { $0.tag == "a" && $0["href"].contains(".html") }
                    ?? card.first { $0.tag == "a" && $0["href"].contains(".html") }
                guard let anchor else { continue }
                let raw = anchor.text.isEmpty ? anchor["title"] : anchor.text
                let cleaned = Self.cleanTitle(raw)
                let year = GermanTitleMatching.year(in: raw) ?? GermanTitleMatching.year(in: card.text)
                guard GermanTitleMatching.matches(cleaned, titles: context.titles),
                      let url = MeinecloudEmbedHelper.normalize(anchor["href"], relativeTo: baseURL),
                      seen.insert(url).inserted else { continue }
                ranked.append((url, cleaned.isEmpty ? raw : cleaned, year))
            }
        }

        return GermanScrape.bestPage(from: ranked, context: context, preferSeason: season)
    }

    private static func cleanTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s*\(\d{4}\)\s*$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\*(English|Subbed)\*\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func movieLinks(in html: String, page: URL) -> [(url: URL, label: String)] {
        let tree = AnimeHTML.parse(html)
        guard let mirrors = tree.first({ $0.hasClass("player-mirrors") }) else { return [] }
        return links(in: mirrors.all { !$0["data-link"].isEmpty }, page: page)
    }

    private static func episodeLinks(
        in html: String,
        page: URL,
        season: Int,
        episode: Int
    ) -> [(url: URL, label: String)] {
        let tree = AnimeHTML.parse(html)
        // Prefer the exact season block. Never silently fall back to season 1
        // when the request is for another season — that mis-binds multi-season shows.
        let entry = tree.first { $0["id"] == "serie-\(season)_\(episode)" }
            ?? tree.first {
                season == 1
                    && $0["id"].hasPrefix("serie-")
                    && $0["id"].hasSuffix("_\(episode)")
            }
        guard let entry else { return [] }
        return links(in: entry.all { !$0["data-link"].isEmpty }, page: page)
    }

    private static func links(in nodes: [AnimeHTML], page: URL) -> [(url: URL, label: String)] {
        var result: [(url: URL, label: String)] = []
        var seen: Set<URL> = []
        for node in nodes {
            // `/vod/vpn` is the site's "use a VPN" interstitial, never a stream.
            let raw = node["data-link"]
            guard !raw.isEmpty, !raw.localizedCaseInsensitiveContains("/vod/vpn") else { continue }
            let candidates = [
                MeinecloudEmbedHelper.decodeDataLink(raw),
                raw.trimmingCharacters(in: .whitespacesAndNewlines),
            ].compactMap { $0 }
            for candidate in candidates {
                guard let url = MeinecloudEmbedHelper.normalize(candidate, relativeTo: page),
                      !(url.hostName ?? "").contains("youtu"),
                      seen.insert(url).inserted else { continue }
                result.append((url, node.text.isEmpty ? MeinecloudEmbedHelper.hosterDisplayName(for: url) : node.text))
                break
            }
        }
        return result
    }
}

// MARK: - MEGAKino

struct MEGAKinoPlaybackProvider: GermanPlaybackProvider {
    var id: String { "megakino" }
    var displayName: String { "MEGAKino" }
    var baseURL: URL { Self.base }

    private static let base = URL(string: "https://megakino.me/")!

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        let session = await Self.openSession()
        guard let page = try await findPage(for: context, session: session) else { return [] }
        let html = try await Self.page(page, referer: session.origin, session: session)

        if let episode = context.request.episode {
            return Self.episodeHosters(in: html, page: page, episode: episode.number)
        }
        let hosters = Self.movieHosters(in: html, page: page, session: session)
        if !hosters.isEmpty { return await GermanScrape.expandingWrappers(hosters) }

        guard let imdb = AnimeHTML.captures(#"(tt\d{7,8})"#, in: html).first?[1],
              let embed = URL(string: "https://meinecloud.click/movie/\(imdb)") else { return [] }
        return await MeinecloudEmbedHelper.expand(embed, referer: page).map {
            GermanHoster(name: $0.name, url: $0.url, referer: embed)
        }
    }

    /// megakino.me hops through numbered mirrors and mints a `yg_token` cookie on
    /// whichever one ends up serving the site, so both have to be carried along.
    private struct Session: Sendable {
        let origin: URL
        let cookies: String?
    }

    private static func openSession() async -> Session {
        guard let token = GermanScrape.url(base, "index.php", query: ["yg": "token"]),
              let response = try? await GermanScrape.client.get(token, referer: base) else {
            return Session(origin: base, cookies: nil)
        }
        var pairs: [String: String] = [:]
        for cookie in GermanScrape.client.cookieStorage.cookies(for: response.url) ?? [] {
            pairs[cookie.name] = cookie.value
        }
        for cookie in response.cookies { pairs[cookie.name] = cookie.value }
        return Session(
            origin: URL(string: response.url.origin) ?? base,
            cookies: pairs.isEmpty ? nil : pairs.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        )
    }

    private static func request(_ url: URL, referer: URL, session: Session) -> URLRequest {
        var request = HosterHTTP.request(url: url, referer: referer)
        if let cookies = session.cookies { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        return request
    }

    private static func page(_ url: URL, referer: URL, session: Session) async throws -> String {
        let response = try await GermanScrape.client.send(request(url, referer: referer, session: session))
        return response.text
    }

    private func findPage(for context: PlaybackLookupContext, session: Self.Session) async throws -> URL? {
        let wantsSeries = context.request.media.kind == .series
        let season = context.request.episode?.seasonNumber
        for query in GermanScrape.queries(for: context) {
            try Task.checkCancellation()
            guard let search = GermanScrape.url(session.origin, "index.php", query: ["do": "search"]) else { continue }
            var request = HosterHTTP.formRequest(url: search, referer: session.origin, fields: [
                "do": "search",
                "subaction": "search",
                "search_start": "1",
                "full_search": "0",
                "result_from": "1",
                "story": query,
            ])
            if let cookies = session.cookies { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
            guard let response = try? await GermanScrape.client.send(request) else { continue }

            var ranked: [(url: URL, title: String, year: Int?)] = []
            var seen = Set<URL>()
            for card in AnimeHTML.parse(response.text).all({ $0.tag == "a" && $0.hasClass("poster") }) {
                let href = card["href"]
                let title = card.first { $0.tag == "h3" && $0.hasClass("poster__title") }?.text ?? ""
                guard !href.isEmpty, !title.isEmpty, href.contains("/serials/") == wantsSeries,
                      GermanTitleMatching.matches(Self.showTitle(title), titles: context.titles),
                      let url = MeinecloudEmbedHelper.normalize(href, relativeTo: session.origin),
                      seen.insert(url).inserted else { continue }
                let year = GermanTitleMatching.year(in: title) ?? GermanTitleMatching.year(in: card.text)
                ranked.append((url, Self.showTitle(title), year))
            }
            if let best = GermanScrape.bestPage(from: ranked, context: context, preferSeason: season) {
                return best
            }
        }
        return nil
    }

    private static func showTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"\s*-\s*\d+\s*Staffel\s*$"#, with: "", options: .regularExpression)
    }

    private static func seasonNumber(in raw: String) -> Int? {
        guard let match = AnimeHTML.captures(#"-\s*(\d+)\s*Staffel"#, in: raw).first else { return nil }
        return Int(match[1])
    }

    private static func movieHosters(in html: String, page: URL, session: Session) -> [GermanHoster] {
        let tree = AnimeHTML.parse(html)
        let tabNames = tree.all { $0.hasClass("tabs-block__select") }
            .flatMap { $0.all { $0.tag == "span" } }
            .map(\.text)
        var result: [GermanHoster] = []
        var seen: Set<URL> = []

        func append(_ raw: String, name: String) {
            guard let url = MeinecloudEmbedHelper.normalize(raw, relativeTo: page),
                  let host = url.hostName, !host.contains("youtu"),
                  !url.path.hasSuffix(".png"), !url.path.hasSuffix(".jpg"),
                  !url.absoluteString.localizedCaseInsensitiveContains("stream-start"),
                  seen.insert(url).inserted else { return }
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = label.isEmpty ? MeinecloudEmbedHelper.hosterDisplayName(for: url) : label
            // `/dl/` pages are soft gates that only expose the embed once opened.
            guard url.path.contains("/dl/") else {
                result.append(GermanHoster(name: display, url: url, referer: page))
                return
            }
            result.append(GermanHoster(name: display, url: url, referer: page, resolve: {
                guard let target = await Self.resolveDownloadGate(url, referer: page, session: session) else {
                    throw AppError.providerUnavailable("MEGAKino verlangt für diesen Stream ein VPN")
                }
                return try await HosterExtractor.resolve(target, referer: url, serverName: display)
            }))
        }

        for (index, content) in tree.all({ $0.hasClass("tabs-block__content") }).enumerated() {
            let name = index < tabNames.count ? tabNames[index] : "Server \(index + 1)"
            if let frame = content.first({ $0.tag == "iframe" }) {
                append(frame["data-src"].isEmpty ? frame["src"] : frame["data-src"], name: name)
            }
            for anchor in content.all({ $0.tag == "a" && $0["href"].contains("/dl/") }) {
                append(anchor["href"], name: anchor.text.isEmpty ? name : anchor.text)
            }
        }
        if result.isEmpty {
            for (index, frame) in tree.all({ $0.tag == "iframe" }).enumerated() {
                append(frame["data-src"].isEmpty ? frame["src"] : frame["data-src"], name: "Server \(index + 1)")
            }
        }
        if result.isEmpty {
            for (index, anchor) in tree.all({ $0.tag == "a" && $0["href"].contains("/dl/") }).enumerated() {
                append(anchor["href"], name: anchor.text.isEmpty ? "Server \(index + 1)" : anchor.text)
            }
        }
        return result
    }

    /// Season pages key each episode's server `<select>` by the option value.
    private static func episodeHosters(in html: String, page: URL, episode: Int) -> [GermanHoster] {
        let tree = AnimeHTML.parse(html)
        let options = tree.all { $0.hasClass("se-select") }.flatMap { $0.all { $0.tag == "option" } }
        let selected = options.enumerated().first { index, option in
            if let match = AnimeHTML.captures(#"Episode\s+(\d+)"#, in: option.text).first { return Int(match[1]) == episode }
            return index + 1 == episode
        }
        guard let identifier = selected?.element["value"], !identifier.isEmpty,
              let list = tree.first({ $0.tag == "select" && $0["id"] == identifier }) else { return [] }

        var result: [GermanHoster] = []
        var seen: Set<URL> = []
        for option in list.all({ $0.tag == "option" }) {
            let raw = option["value"]
            guard raw.hasPrefix("http") || raw.hasPrefix("//"),
                  !raw.localizedCaseInsensitiveContains("youtu"),
                  let url = MeinecloudEmbedHelper.normalize(raw, relativeTo: page),
                  seen.insert(url).inserted else { continue }
            let name = option.text.isEmpty ? MeinecloudEmbedHelper.hosterDisplayName(for: url) : option.text
            result.append(GermanHoster(name: name, url: url, referer: page))
        }
        return result
    }

    private static func resolveDownloadGate(_ url: URL, referer: URL, session: Session) async -> URL? {
        guard let html = try? await page(url, referer: referer, session: session) else { return nil }
        let tree = AnimeHTML.parse(html)
        let text = tree.text
        if text.localizedCaseInsensitiveContains("VPN"),
           text.localizedCaseInsensitiveContains("Verschlüsselung") || text.localizedCaseInsensitiveContains("einrichten") {
            return nil
        }
        if let frame = tree.first({ $0.tag == "iframe" && !($0["src"].isEmpty && $0["data-src"].isEmpty) }) {
            let raw = frame["data-src"].isEmpty ? frame["src"] : frame["data-src"]
            if !raw.localizedCaseInsensitiveContains("youtu"),
               let resolved = MeinecloudEmbedHelper.normalize(raw, relativeTo: url) {
                return resolved
            }
        }
        let known = ["voe", "mixdrop", "streamtape", "vidoza", "dood", "filemoon", "meinecloud"]
        guard let anchor = tree.first({ node in
            node.tag == "a" && known.contains { node["href"].localizedCaseInsensitiveContains($0) }
        }) else { return nil }
        return MeinecloudEmbedHelper.normalize(anchor["href"], relativeTo: url)
    }
}

// MARK: - SerienStream

/// Series only. The default host is the serien.domains CUII proxy, which is
/// cleartext HTTP; the hostname mirrors keep HTTPS.
struct SerienStreamPlaybackProvider: GermanPlaybackProvider {
    var id: String { "serienstream" }
    var displayName: String { "SerienStream" }
    var baseURL: URL { preferredOrigins[0] }
    var supportsMovies: Bool { false }

    private static let origins = [
        URL(string: "http://186.2.175.5/")!,
        URL(string: "https://serienstream.to/")!,
        URL(string: "https://serienstream.cx/")!,
    ]
    private static let workingOriginKey = "serienstream.workingOrigin"

    /// Prefer the last working domain (Android persists this) before trying the rest.
    private var preferredOrigins: [URL] {
        var ordered = Self.origins
        if let raw = UserDefaults.standard.string(forKey: Self.workingOriginKey),
           let saved = URL(string: raw),
           let index = ordered.firstIndex(where: { $0.host == saved.host && $0.scheme == saved.scheme }) {
            ordered.move(fromOffsets: IndexSet(integer: index), toOffset: 0)
        }
        return ordered
    }

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        guard let episode = context.request.episode else { return [] }
        for origin in preferredOrigins {
            try Task.checkCancellation()
            guard let slug = try? await findSlug(for: context, origin: origin) else { continue }
            guard let page = GermanScrape.url(
                origin,
                "serie/\(GermanScrape.pathEncoded(slug))/staffel-\(episode.seasonNumber)/episode-\(episode.number)"
            ), let html = try? await GermanScrape.client.page(page, referer: origin) else { continue }
            let hosters = Self.linkBoxes(in: html, page: page, origin: origin)
            if !hosters.isEmpty {
                UserDefaults.standard.set(origin.absoluteString, forKey: Self.workingOriginKey)
                return hosters
            }
        }
        return []
    }

    private func findSlug(for context: PlaybackLookupContext, origin: URL) async throws -> String? {
        for query in GermanScrape.queries(for: context) {
            try Task.checkCancellation()
            guard let search = GermanScrape.url(origin, "suche", query: ["term": query, "page": "1", "tab": "shows"]),
                  let html = try? await GermanScrape.client.page(search, referer: origin) else { continue }
            var ranked: [(url: URL, title: String, year: Int?)] = []
            var seen = Set<String>()
            for card in AnimeHTML.parse(html).all({ $0.hasClass("cover-card") }) {
                guard let anchor = card.first({ $0.tag == "a" && $0["href"].hasPrefix("/serie/") }) else { continue }
                let title = card.first { $0.tag == "h6" && $0.hasClass("show-title") }?.text ?? ""
                let year = GermanTitleMatching.year(in: card.text) ?? GermanTitleMatching.year(in: title)
                guard GermanTitleMatching.matches(title, titles: context.titles) else { continue }
                let slug = anchor["href"].components(separatedBy: "/").filter { !$0.isEmpty }.last
                guard let slug, !slug.isEmpty, seen.insert(slug).inserted,
                      let placeholder = URL(string: "https://serienstream.to/\(slug)") else { continue }
                ranked.append((placeholder, title, year))
            }
            if let best = GermanScrape.bestPage(from: ranked, context: context) {
                return best.lastPathComponent
            }
        }
        return nil
    }

    private static func linkBoxes(in html: String, page: URL, origin: URL) -> [GermanHoster] {
        AnimeHTML.parse(html).all { $0.tag == "button" && $0.hasClass("link-box") }.compactMap { button in
            let href = button["data-play-url"]
            guard !href.isEmpty, let play = MeinecloudEmbedHelper.normalize(href, relativeTo: origin) else { return nil }
            let provider = button["data-provider-name"].isEmpty ? "Host" : button["data-provider-name"]
            let label = button["data-language-label"]
            let name = label.isEmpty ? provider : "\(provider) (\(label))"
            return GermanHoster(
                name: name,
                url: play,
                referer: page,
                audioLanguage: Self.audioLanguage(for: label),
                resolve: { try await Self.resolvePlayURL(play, referer: page, serverName: name) }
            )
        }
    }

    /// `/r?` play URLs answer with the hoster redirect, or with a challenge page
    /// whose iframe still points at it.
    private static func resolvePlayURL(_ play: URL, referer: URL, serverName: String) async throws -> PlaybackSource {
        let response = try await GermanScrape.client.get(play, referer: referer)
        if !isSiteURL(response.url) {
            return try await HosterExtractor.resolve(response.url, referer: referer, serverName: serverName)
        }
        let pattern = #"(?:src|data-src)\s*=\s*["'](https?://[^"']+)["']"#
        for match in AnimeHTML.captures(pattern, in: response.text) {
            guard let url = URL(string: match[1]), !isSiteURL(url),
                  !match[1].localizedCaseInsensitiveContains("cloudflare"),
                  !match[1].localizedCaseInsensitiveContains("youtu") else { continue }
            return try await HosterExtractor.resolve(url, referer: referer, serverName: serverName)
        }
        throw AppError.providerUnavailable("SerienStream verification gate is still active")
    }

    private static func isSiteURL(_ url: URL) -> Bool {
        if url.absoluteString.localizedCaseInsensitiveContains("/r?") { return true }
        let host = (url.hostName ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        if host == "186.2.175.5" || host == "challenges.cloudflare.com" { return true }
        return ["serienstream.to", "serienstream.cx"].contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func audioLanguage(for label: String) -> String {
        let lowered = label.lowercased()
        if lowered.hasPrefix("deutsch") || lowered.contains("ger dub") { return "de" }
        if lowered.contains("japan") { return "ja" }
        if lowered.contains("eng") { return "en" }
        return "de"
    }
}

// MARK: - AniWorld

/// Anime only. `data-lang-key` distinguishes the German dub from the subtitled
/// Japanese audio tracks.
struct AniWorldPlaybackProvider: GermanPlaybackProvider {
    var id: String { "aniworld" }
    var displayName: String { "AniWorld" }
    var baseURL: URL { Self.base }
    var supportsMovies: Bool { false }

    private static let base = URL(string: "https://aniworld.to/")!

    func hosters(for context: PlaybackLookupContext) async throws -> [GermanHoster] {
        guard let episode = context.request.episode, let slug = try await findSlug(for: context) else { return [] }
        guard let page = GermanScrape.url(
            baseURL,
            "anime/stream/\(GermanScrape.pathEncoded(slug))/staffel-\(episode.seasonNumber)/episode-\(episode.number)"
        ) else { return [] }
        let html = try await GermanScrape.client.page(page, referer: baseURL)
        return Self.hosterList(in: html, page: page)
    }

    private func findSlug(for context: PlaybackLookupContext) async throws -> String? {
        guard let search = GermanScrape.url(baseURL, "ajax/search") else { return nil }
        for query in GermanScrape.queries(for: context) {
            try Task.checkCancellation()
            let request = HosterHTTP.formRequest(url: search, referer: baseURL, fields: ["keyword": query])
            guard let response = try? await GermanScrape.client.send(request),
                  let results = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else { continue }

            var ranked: [(url: URL, title: String, year: Int?)] = []
            var seen = Set<String>()
            for result in results {
                guard let link = GermanScrape.scalar(result["link"]),
                      let raw = GermanScrape.scalar(result["title"]) else { continue }
                let slug = link
                    .components(separatedBy: "/anime/stream/").last?
                    .components(separatedBy: "/").first ?? ""
                let title = HTMLPayloadParser.decodeEntities(
                    raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                )
                let year = GermanScrape.scalar(result["year"]).flatMap(Int.init)
                    ?? GermanTitleMatching.year(in: title)
                guard !slug.isEmpty, link.contains("/anime/stream/"),
                      GermanTitleMatching.matches(title, titles: context.titles),
                      seen.insert(slug).inserted,
                      let placeholder = URL(string: "https://aniworld.to/\(slug)") else { continue }
                ranked.append((placeholder, title, year))
            }
            if let best = GermanScrape.bestPage(from: ranked, context: context) {
                return best.lastPathComponent
            }
        }
        return nil
    }

    private static func hosterList(in html: String, page: URL) -> [GermanHoster] {
        let tree = AnimeHTML.parse(html)
        guard let container = tree.first({ $0.hasClass("hosterSiteVideo") }) else { return [] }
        var result: [GermanHoster] = []
        var seen: Set<URL> = []

        for item in container.all({ $0.tag == "li" }) {
            guard let anchor = item.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                  let redirect = MeinecloudEmbedHelper.normalize(anchor["href"], relativeTo: base),
                  seen.insert(redirect).inserted else { continue }
            let hoster = item.first { $0.tag == "h4" }?.text ?? ""
            guard !hoster.isEmpty else { continue }

            let suffix: String
            let language: String
            let subtitles: StreamSubtitleKind
            switch item["data-lang-key"] {
            case "1": suffix = " - DUB"; language = "de"; subtitles = .unknown
            case "2": suffix = " - SUB English"; language = "ja"; subtitles = .embeddedEnglish
            case "3": suffix = " - SUB"; language = "ja"; subtitles = .unknown
            default: suffix = ""; language = "de"; subtitles = .unknown
            }
            let name = hoster + suffix

            result.append(GermanHoster(
                name: name,
                url: redirect,
                referer: page,
                audioLanguage: language,
                subtitleKind: subtitles,
                resolve: {
                    try await GermanScrape.followRedirect(
                        redirect,
                        referer: page,
                        serverName: hoster,
                        voePrefix: "https://voe.sx/"
                    )
                }
            ))
        }
        return result
    }
}

// MARK: - Registry

enum GermanPlaybackProviders {
    static func all() -> [any PlaybackProvider] {
        [
            EinschaltenPlaybackProvider(),
            MStreamPlaybackProvider(),
            FilmPalastPlaybackProvider(),
            FilmoPlaybackProvider(),
            HDFilmePlaybackProvider(),
            KinoGerPlaybackProvider(),
            MEGAKinoPlaybackProvider(),
            SerienStreamPlaybackProvider(),
            AniWorldPlaybackProvider(),
        ]
    }
}
