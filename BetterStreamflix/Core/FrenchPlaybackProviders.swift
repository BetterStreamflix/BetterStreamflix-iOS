import Foundation

/// French-language BetterStreamflix providers ported from the Android catalogue.

// MARK: - Wiflix

/// DLE site whose player tabs call `loadVideo('url')`.
struct WiflixPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "wiflix" }
    var displayName: String { "Wiflix" }
    var audioLanguage: String { "fr" }
    var baseURL: URL { URL(string: "https://www.neufneuf.space/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("index.php", query: ["do": "search"]), form: [
                "do": "search",
                "subaction": "search",
                "story": query,
                "search_start": "1",
                "full_search": "1",
            ])
            let results = search.all { $0.hasClass("mov") }.compactMap { mov -> ScrapedResult? in
                guard let anchor = mov.first({ $0.tag == "a" && $0.hasClass("mov-t") }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let href = anchor["href"]
                let isMovie = href.contains("film-en-streaming/") || href.contains("film-ancien/")
                let isSeries = href.contains("serie-en-streaming/") || href.contains("/vf/")
                guard isMovie || isSeries else { return nil }
                // Each season is its own page, labelled in the result badge.
                if let episode = context.request.episode,
                   let badge = mov.first({ $0.hasClass("block-sai") })?.text,
                   let capture = AnimeHTML.captures(#"(\d+)"#, in: badge).first,
                   Int(capture[1]) != episode.seasonNumber { return nil }
                return ScrapedResult(title: anchor.text, kind: isMovie ? .movie : .series, url: page)
            }
            guard let match = results.bestMatch(for: context) else { continue }

            let document = try await html(match.url)
            let anchors: [AnimeHTML]
            if let episode = context.request.episode {
                // An episode entry names the block that holds its mirrors.
                guard let entry = document.first({ node in
                    guard node.tag == "li", !node["rel"].isEmpty else { return false }
                    return AnimeHTML.captures(#"episode\s*(\d+)"#, in: node.text)
                        .first.flatMap { Int($0[1]) } == episode.number
                }) else { continue }
                anchors = document.all { $0.hasClass(entry["rel"]) }.flatMap { $0.all { $0.tag == "a" } }
            } else {
                anchors = document.all { $0.hasClass("tabs-sel") }.flatMap { $0.all { $0.tag == "a" } }
            }

            let links = anchors.compactMap { anchor -> HosterLink? in
                guard let capture = AnimeHTML.captures(#"loadVideo\(\s*'([^']+)'"#, in: anchor["onclick"]).first,
                      let target = ProviderNetwork.absolute(capture[1], relativeTo: match.url) else { return nil }
                let label = anchor.first { $0.tag == "span" }?.text ?? ""
                return HosterLink(
                    name: label.isEmpty ? (target.host ?? "Server") : label,
                    url: target,
                    referer: match.url,
                    audioLanguage: "fr"
                )
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - French Anime

/// The show page keeps every episode in one `div.eps` blob shaped
/// `number!url,url,url`.
struct FrenchAnimePlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "frenchanime" }
    var displayName: String { "French Anime" }
    var audioLanguage: String { "fr" }
    var baseURL: URL { URL(string: "https://french-anime.com/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        for query in TitleMatch.queries(for: context) {
            let search = try await html(baseURL, form: [
                "do": "search",
                "subaction": "search",
                "story": query,
                "search_start": "1",
                "full_search": "0",
            ])
            let results = search.all { $0.hasClass("mov") }.compactMap { mov -> ScrapedResult? in
                guard let anchor = mov.first({ $0.tag == "a" && $0.hasClass("mov-t") }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                return ScrapedResult(
                    title: anchor.text,
                    kind: mov.first { $0.hasClass("block-ep") } != nil ? .series : .movie,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }

            let document = try await html(match.url)
            guard let blob = document.first({ $0.hasClass("eps") })?.text else { continue }
            let wanted = context.request.episode.map { context.continuousEpisodeNumber ?? $0.number }
            let entries = blob.split(separator: " ").map(String.init)
            let entry = entries.first { candidate in
                let parts = candidate.split(separator: "!", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { return false }
                guard let wanted else { return true }
                return Int(parts[0]) == wanted
            }
            guard let entry, let sources = entry.split(separator: "!", maxSplits: 1).last else { continue }

            let links = sources.split(separator: ",").compactMap { source -> HosterLink? in
                guard let target = ProviderNetwork.absolute(String(source), relativeTo: match.url) else { return nil }
                return HosterLink(
                    name: target.host ?? "Server",
                    url: target,
                    referer: match.url,
                    audioLanguage: "fr"
                )
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - French Stream

/// DLE ajax endpoints: `film_api.php` for movies, `sx.php` for episodes.
struct FrenchStreamPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "frenchstream" }
    var displayName: String { "French Stream" }
    var audioLanguage: String { "fr" }
    var baseURL: URL { URL(string: "https://fs23.lol/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let results = try await FrenchDLE.search(query: query, provider: self, context: context)
            guard let match = results.first else { continue }

            let links: [HosterLink]
            if let episode = context.request.episode {
                let payload = try await jsonObject(
                    url("engine/ajax/sx.php", query: ["id": match.identifier]),
                    referer: baseURL,
                    headers: FrenchDLE.headers(skin: "VFV1")
                )
                links = FrenchDLE.episodeLinks(in: payload, number: episode.number, relativeTo: baseURL)
            } else {
                let payload = try await jsonObject(
                    url("engine/ajax/film_api.php", query: ["id": match.newsID]),
                    referer: baseURL,
                    headers: FrenchDLE.headers(skin: "VFV1")
                )
                links = Self.movieLinks(in: payload, relativeTo: baseURL)
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    /// `players` maps a hoster to one url per audio language.
    private static func movieLinks(in payload: [String: Any], relativeTo base: URL) -> [HosterLink] {
        guard let players = payload["players"] as? [String: Any] else { return [] }
        let labels = ["vff": "TrueFrench", "vfq": "French", "vostfr": "VOSTFR", "vo": "VO"]
        var links: [HosterLink] = []
        for (provider, value) in players {
            guard let languages = value as? [String: Any] else { continue }
            for (language, raw) in languages {
                guard let raw = raw as? String, !raw.isEmpty,
                      let target = ProviderNetwork.absolute(raw, relativeTo: base) else { continue }
                let label = language == "default" ? "" : (labels[language] ?? language)
                links.append(HosterLink(
                    name: label.isEmpty ? provider : "\(provider) (\(label))",
                    url: target,
                    referer: base,
                    audioLanguage: language == "vo" ? "en" : "fr"
                ))
            }
        }
        return links
    }
}

// MARK: - Frembed

/// TMDB-keyed json api that answers with one redirect url per mirror.
struct FrembedPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "frembed" }
    var displayName: String { "Frembed" }
    var audioLanguage: String { "fr" }
    var baseURL: URL { URL(string: "https://frembed.surf/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard let tmdbID = context.request.media.tmdbID else { return [] }

        var payload: [String: Any]?
        if let episode = context.request.episode {
            payload = try? await jsonObject(url("api/series", query: [
                "id": String(tmdbID),
                "sa": String(episode.seasonNumber),
                "epi": String(episode.number),
                "idType": "tmdb",
            ]))
        } else {
            payload = try? await jsonObject(url("api/films", query: [
                "id": String(tmdbID), "idType": "tmdb",
            ]))
            if Self.links(in: payload ?? [:], relativeTo: baseURL).isEmpty,
               let imdbID = context.request.media.imdbID?.nonEmpty {
                let identifier = imdbID.hasPrefix("tt") ? imdbID : "tt\(imdbID)"
                payload = try? await jsonObject(url("api/films", query: [
                    "id": identifier, "idType": "imdb",
                ]))
            }
        }
        return Self.links(in: payload ?? [:], relativeTo: baseURL)
    }

    private static func links(in payload: [String: Any], relativeTo base: URL) -> [HosterLink] {
        if let entries = payload["links"] as? [[String: Any]], !entries.isEmpty {
            return entries.compactMap { entry in
                guard let raw = entry["url"] as? String,
                      let target = ProviderNetwork.absolute(raw, relativeTo: base) else { return nil }
                let language = Self.language(entry["lang"] as? String)
                let host = (entry["host"] as? [String: Any])?["name"] as? String
                let name = host ?? (entry["label"] as? String) ?? target.host ?? "Server"
                return HosterLink(
                    name: "\(name) (\(language.label))",
                    url: target,
                    referer: base,
                    audioLanguage: language.code
                )
            }
        }

        var links: [HosterLink] = []
        var slots: [(String, String)] = []
        for index in 1...7 {
            slots.append(("link\(index)", "French"))
            slots.append(("link\(index)vostfr", "VOSTFR"))
            slots.append(("link\(index)vo", "VO"))
        }
        slots.append(("link", "French"))
        slots.append(("link_vostfr", "VOSTFR"))

        for (key, label) in slots {
            guard let raw = payload[key] as? String, !raw.isEmpty,
                  let target = ProviderNetwork.absolute(raw, relativeTo: base) else { continue }
            links.append(HosterLink(
                name: "\(target.host ?? "Server") (\(label))",
                url: target,
                referer: base,
                audioLanguage: label == "VO" ? "en" : "fr"
            ))
        }
        return links
    }

    private static func language(_ value: String?) -> (code: String, label: String) {
        switch value?.lowercased() {
        case "vostfr": return ("fr", "VOSTFR")
        case "vo", "en", "vost": return ("en", "VO")
        default: return ("fr", "French")
        }
    }
}

// MARK: - Kidraz

/// Movies only. A small json api lists the films, and each film page embeds one
/// iframe.
struct KidrazPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "kidraz" }
    var displayName: String { "Kidraz" }
    var audioLanguage: String { "fr" }
    var supportsSeries: Bool { false }
    var baseURL: URL { URL(string: "https://www.kidraz.com/")! }

    private static let folder = "saby1jy"
    private static let portal = "kidraz"

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let response = try await jsonObject(url("\(Self.folder)/api_search.php", query: [
                "searchword": query,
                "offset": "0",
                "limit": "20",
                "folder": Self.folder,
                "pr": Self.portal,
            ]))
            let films = (response["films"] as? [[String: Any]]) ?? []
            guard let film = films.first(where: { film in
                guard let title = film["title"] as? String else { return false }
                return TitleMatch.matches(title, year: TitleMatch.year(title), context: context)
            }), let link = film["link"] as? String,
                let page = ProviderNetwork.absolute(link, relativeTo: baseURL) else { continue }

            let document = try await html(page)
            let links = embedLinks(in: document, page: page, named: "Kidraz")
                .map { HosterLink(name: $0.url.host ?? $0.name, url: $0.url, referer: page, audioLanguage: "fr") }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - French Manga

/// Series only. Shares the DLE search of French Stream, with its own episode api.
struct FrenchMangaPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "frenchmanga" }
    var displayName: String { "French Manga" }
    var audioLanguage: String { "fr" }
    var supportsMovies: Bool { false }
    var baseURL: URL { URL(string: "https://w16.french-manga.net/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard let episode = context.request.episode else { return [] }
        let number = context.continuousEpisodeNumber ?? episode.number
        for query in TitleMatch.queries(for: context) {
            let results = try await FrenchDLE.search(query: query, provider: self, context: context)
            guard let match = results.first else { continue }
            let payload = try await jsonObject(
                url("engine/ajax/manga_episodes_api.php", query: ["id": match.identifier]),
                referer: baseURL,
                headers: FrenchDLE.headers(skin: "MGV1")
            )
            let links = FrenchDLE.episodeLinks(in: payload, number: number, relativeTo: baseURL)
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - UnJourUnFilm

/// DooPlay theme reached through the standard `doo_player_ajax` action.
struct UnJourUnFilmPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "unjourunfilm" }
    var displayName: String { "1jour1film" }
    var audioLanguage: String { "fr" }
    var baseURL: URL { URL(string: "https://1jour1film0826b.website/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.hasClass("result-item") }
                .compactMap { item -> ScrapedResult? in
                    guard let anchor = item.first({ node in
                        node.tag == "a" && !node["href"].isEmpty
                            && (node["href"].contains("/films/") || node["href"].contains("/tvshows/"))
                    }), let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = item.first { $0.hasClass("title") }?.text ?? anchor.text
                    return ScrapedResult(
                        title: title,
                        year: TitleMatch.year(item.first { $0.hasClass("year") }?.text),
                        kind: anchor["href"].contains("/tvshows/") ? .series : .movie,
                        url: page
                    )
                }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                guard let resolved = try await DooPlay.episodeURL(
                    show: match.url, episode: episode, provider: self
                ) else { continue }
                page = resolved
            }

            let document = try await html(page)
            let type = context.request.episode == nil ? "movie" : "tv"
            var links: [HosterLink] = []
            for option in document.all({ !$0["data-nume"].isEmpty && !$0["data-post"].isEmpty }) {
                guard let payload = try? await jsonObject(
                    url("wp-admin/admin-ajax.php"),
                    referer: page,
                    headers: ["X-Requested-With": "XMLHttpRequest"],
                    form: [
                        "action": "doo_player_ajax",
                        "post": option["data-post"],
                        "nume": option["data-nume"],
                        "type": option["data-type"].nonEmpty ?? type,
                    ]
                ), let raw = payload["embed_url"] as? String,
                    let embed = ProviderNetwork.absolute(raw, relativeTo: page) else { continue }
                let label = option.first { $0.hasClass("title") }?.text ?? ""
                links.append(HosterLink(
                    name: label.isEmpty ? (embed.host ?? "Server") : label,
                    url: embed,
                    referer: page,
                    audioLanguage: "fr"
                ))
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - AfterDark

/// TMDB-keyed aggregator: every backend is one `_serverFn` call returning a
/// flattened key/value payload with direct files.
struct AfterDarkPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "afterdark" }
    var displayName: String { "AfterDark" }
    var audioLanguage: String { "fr" }
    var baseURL: URL { URL(string: "https://afterdark.rest/")! }

    private static let backends: [(name: String, hash: String)] = [
        ("Premium", "aa86800c3ec95e610210f8378c316734ee92a09ee00f8c708c1a06c616651e8f"),
        ("Raven", "63e997074c73a7b57239e53ac7618f3e1ef81bda3f0ab47ee0ecc82bf0493904"),
        ("Willow", "ffe22be1dcd9d941bd4d09121338c70500fc067dcd94b1168079ba789e7c46c4"),
        ("Alpha", "d7ae23a39378ba1864d998d52c010e969f8344ebaebf97436d9c7bf3b592667d"),
        ("Yuna", "24758778992d2473ae2618adf856f8902a675718eef18169c854d07d1fcad298"),
        ("Ive", "70b726570a3111d2c6d51ae57139e4af4b69392ebbf32293c5d7f7ec53922cd5"),
        ("Lumi", "e818c6028fbd6b8c58ce3cdb1d8be2972ffa0a486361fc07b7e9d2bd0c2d95f2"),
        ("Beta", "e89c6cdf5d5296dd5f0e864a030efdfcaa1896773fb9f0d7e6926acaed7f4a86"),
        ("Bunny", "dc4cc6245be6fec3d7ea391bfac09cb5d4090e5135629b0e6e81bacd3d10e8dc"),
        ("Gamma", "c3ce337885c3aae80534c9fa298aae6a4b37fa0188c09238610beeacd553caf1"),
    ]

    private static let proxies = [
        "voe": "https://proxy.afterdark.baby/boom-clap?url=",
        "vidmoly": "https://proxy.afterdark.baby/elizabeth-taylor?url=",
        "uqload": "https://proxy.afterdark.baby/alejandro?url=",
        "vidzy": "https://proxy.afterdark.baby/rolly?url=",
    ]

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard let tmdbID = context.request.media.tmdbID else { return [] }
        let media = context.request.media
        let payload = Self.payload(
            title: media.title,
            type: context.request.episode == nil ? "movie" : "tv",
            tmdbID: String(tmdbID),
            imdbID: media.imdbID?.nonEmpty ?? "0",
            year: TitleMatch.year(media.releaseDate).map(String.init) ?? "",
            season: context.request.episode?.seasonNumber ?? 1,
            episode: context.request.episode?.number ?? 1
        )
        let encoded = ProviderNetwork.encoded(payload)

        return await withTaskGroup(of: [HosterLink].self) { group in
            for backend in Self.backends {
                group.addTask {
                    guard let endpoint = URL(
                        string: "\(baseURL.absoluteString)_serverFn/\(backend.hash)?payload=\(encoded)"
                    ) else { return [] }
                    guard let body = try? await text(endpoint, referer: baseURL, headers: [
                        "X-Requested-With": "XMLHttpRequest",
                        "x-tsr-serverfn": "true",
                    ]), !body.contains("\"error\":") else { return [] }
                    return Self.parse(body, backend: backend.name, referer: baseURL)
                }
            }
            var links: [HosterLink] = []
            for await batch in group { links += batch }
            return links
        }
    }

    private static func payload(
        title: String, type: String, tmdbID: String, imdbID: String,
        year: String, season: Int, episode: Int
    ) -> String {
        let fields = """
        {"k":["title","type","tmdbId","imdbId","releaseYear","season","episode"],\
        "v":[{"t":1,"s":"\(title)"},{"t":1,"s":"\(type)"},{"t":1,"s":"\(tmdbID)"},\
        {"t":1,"s":"\(imdbID)"},{"t":1,"s":"\(year)"},{"t":2,"s":\(season)},{"t":2,"s":\(episode)}]}
        """
        return """
        {"t":{"t":10,"i":0,"p":{"k":["data"],"v":[{"t":10,"i":1,"p":\(fields),"o":0}]},"o":0},"f":63,"m":[]}
        """
    }

    /// The response flattens objects into parallel key and value arrays.
    private static func parse(_ body: String, backend: String, referer: URL) -> [HosterLink] {
        var links: [HosterLink] = []
        var seen: Set<String> = []
        for block in AnimeHTML.captures(#""k":\[([^\]]+)\],"v":\[([^\]]+)\]"#, in: body) {
            let keys = block[1].split(separator: ",").map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
            let values = AnimeHTML.captures(#""s":"([^"]*)""#, in: block[2]).map { $0[1] }
            guard keys.count == values.count else { continue }
            let entry = Dictionary(zip(keys, values), uniquingKeysWith: { first, _ in first })

            let service = (entry["service"] ?? "").lowercased()
            guard let raw = entry["url"] ?? entry["embedUrl"], raw.hasPrefix("http") else { continue }
            let proxy = proxies[service]
            // The site itself only offers premium links, proxied hosters and
            // unrecognised services; anything else is a dead mirror.
            guard backend == "Premium" || proxy != nil || service.isEmpty || service == "unknown" else { continue }
            let value = proxy.map { $0 + ProviderNetwork.encoded(raw) } ?? raw
            guard let target = ProviderNetwork.absolute(value, relativeTo: referer),
                  seen.insert(target.absoluteString).inserted else { continue }

            let name = [
                entry["provider"] ?? backend,
                entry["quality"] ?? "hd",
                entry["language"] ?? "vf",
            ].joined(separator: " · ")
            let direct = target.path.contains(".m3u8") || target.path.contains(".mp4")
            links.append(HosterLink(
                name: name,
                url: target,
                referer: referer,
                audioLanguage: (entry["language"] ?? "vf").lowercased().hasPrefix("v") ? "fr" : "en",
                isDirect: direct,
                headers: direct ? HosterResolver.headers(for: target, referer: referer) : [:]
            ))
        }
        return links
    }
}

// MARK: - Shared DLE helpers

/// French Stream and French Manga run the same DLE skin: a json search endpoint
/// plus an episode api keyed by audio language.
enum FrenchDLE {
    struct Result: Sendable {
        let title: String
        /// The site's own id, e.g. `1234-title-saison-2.html`.
        let identifier: String
        /// The numeric DLE post id the movie api expects.
        let newsID: String
    }

    static func headers(skin: String) -> [String: String] {
        ["Cookie": "dle_skin=\(skin)", "X-Requested-With": "XMLHttpRequest"]
    }

    static func search(
        query: String,
        provider: some ScrapedPlaybackProvider,
        context: PlaybackLookupContext
    ) async throws -> [Result] {
        let document = try await provider.html(
            provider.url("engine/ajax/search.php"),
            form: ["query": query, "page": "1"]
        )
        let season = context.request.episode?.seasonNumber
        return document.all { $0.hasClass("search-item") }.compactMap { item -> Result? in
            let identifier = AnimeHTML.captures(#"['"]/?([^'"]+)['"]"#, in: item["onclick"])
                .first.map { $0[1].components(separatedBy: "/").last ?? $0[1] } ?? ""
            guard !identifier.isEmpty else { return nil }
            let title = (item.first { $0.hasClass("search-title") }?.text ?? "")
                .replacingOccurrences(of: "\\'", with: "'")
            guard TitleMatch.matches(title, context: context) else { return nil }
            if let season {
                let labelled = AnimeHTML.captures(#"saison[\s-]*(\d+)"#, in: "\(title) \(identifier)")
                    .first.flatMap { Int($0[1]) }
                guard labelled == nil || labelled == season else { return nil }
            } else if identifier.contains("-saison-") {
                return nil
            }
            let newsID = identifier.contains("newsid=")
                ? identifier.components(separatedBy: "newsid=")[1]
                : (AnimeHTML.captures(#"(\d+)"#, in: identifier).first?[1] ?? identifier)
            return Result(title: title, identifier: identifier, newsID: newsID)
        }
    }

    /// `{ "vf": { "3": { "hoster": "url" } } }`, one bucket per audio language.
    static func episodeLinks(in payload: [String: Any], number: Int, relativeTo base: URL) -> [HosterLink] {
        var links: [HosterLink] = []
        for (bucket, label, language) in [("vf", "VF", "fr"), ("vostfr", "VOSTFR", "fr"), ("vo", "VO", "en")] {
            guard let episodes = payload[bucket] as? [String: Any],
                  let entry = episodes[String(number)] as? [String: Any] else { continue }
            for (hoster, raw) in entry {
                guard let raw = raw as? String,
                      let target = ProviderNetwork.absolute(raw, relativeTo: base) else { continue }
                links.append(HosterLink(
                    name: "\(hoster) (\(label))",
                    url: target,
                    referer: base,
                    audioLanguage: language
                ))
            }
        }
        return links
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
