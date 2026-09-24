import Foundation

/// Italian-language BetterStreamflix providers ported from the Android catalogue.

// MARK: - Altadefinizione01

/// DLE search, then either the GuardaHD mirror list (movies) or the per-season
/// episode list whose mirrors sit next to each episode anchor.
struct Altadefinizione01PlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "altadefinizione01" }
    var displayName: String { "Altadefinizione01" }
    var audioLanguage: String { "it" }
    var baseURL: URL { URL(string: "https://altadefinizione-01.fun/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("index.php", query: [
                "do": "search", "subaction": "search", "titleonly": "3",
                "story": query, "full_search": "0",
            ]))
            let results = search.all { $0.hasClass("boxgrid") }.compactMap { item -> ScrapedResult? in
                guard let anchor = item.all({ $0.tag == "a" && !$0["href"].isEmpty })
                    .first(where: { $0.ancestor { node in node.tag == "h2" || node.tag == "h3" } != nil }),
                    let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let isSeries = item.first { $0.hasClass("se_num") } != nil
                    || anchor["href"].contains("/serie-tv/")
                return ScrapedResult(
                    title: anchor.text,
                    year: TitleMatch.year(item.text),
                    kind: isSeries ? .series : .movie,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }
            let document = try await html(match.url)

            if let episode = context.request.episode {
                var links: [HosterLink] = []
                if let pane = document.first({ $0["id"] == "season-\(episode.seasonNumber)" }) {
                    let anchors = pane.all { $0.tag == "a" && !$0["data-link"].isEmpty }
                    if let row = anchors.first(where: { node in
                        let number = node["data-num"].components(separatedBy: "x").last.flatMap { Int($0) }
                        return (number ?? Int(node.text.trimmingCharacters(in: .whitespaces))) == episode.number
                    })?.parent {
                        links = row.all { $0.tag == "a" && !$0["data-link"].isEmpty }
                            .filter { !$0.text.lowercased().contains("4k") }
                            .compactMap { node in
                                guard let embed = ProviderNetwork.absolute(node["data-link"], relativeTo: match.url) else { return nil }
                                let label = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                                return HosterLink(name: label.isEmpty ? "Server" : label, url: embed, referer: match.url)
                            }
                    }
                }
                if let imdb = Self.imdbID(in: document),
                   let vidxgo = URL(string: "https://v.vidxgo.co/t/\(imdb)/\(episode.seasonNumber)/\(episode.number)") {
                    links.append(HosterLink(name: "VidxGo", url: vidxgo, referer: match.url))
                }
                if !links.isEmpty { return links }
                continue
            }

            if let frame = document.first({ $0.tag == "iframe" && $0["src"].contains("guardahd") }),
               let embedPage = ProviderNetwork.absolute(frame["src"], relativeTo: match.url) {
                let mirrors = try await html(embedPage, referer: match.url)
                let links = mirrors.all { $0.tag == "li" && !$0["data-link"].isEmpty }
                    .filter { !$0.hasClass("fullhd") && !$0.text.lowercased().contains("4k") }
                    .compactMap { node -> HosterLink? in
                        guard let embed = ProviderNetwork.absolute(node["data-link"], relativeTo: embedPage) else { return nil }
                        let label = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        return HosterLink(name: label.isEmpty ? "Server" : label, url: embed, referer: embedPage)
                    }
                if !links.isEmpty { return links }
            }
            if let imdb = Self.imdbID(in: document), let vidxgo = URL(string: "https://v.vidxgo.co/\(imdb)") {
                return [HosterLink(name: "VidxGo", url: vidxgo, referer: match.url)]
            }
        }
        return []
    }

    private static func imdbID(in tree: AnimeHTML) -> String? {
        let scripts = tree.all { $0.tag == "script" }.map(\.text).joined(separator: "\n")
        return AnimeHTML.captures(#"var\s+imdb\s*=\s*['"]tt(\d+)['"]"#, in: scripts).first?[1]
    }
}

// MARK: - GuardaFlix

/// Movies only. The current player serves its own HLS playlist keyed by IMDb id;
/// older posts still carry `aa-options` iframes.
struct GuardaFlixPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "guardaflix" }
    var displayName: String { "GuardaFlix" }
    var audioLanguage: String { "it" }
    var supportsSeries: Bool { false }
    var baseURL: URL { URL(string: "https://www.guardaflix.org/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.tag == "a" && $0["href"].contains("/film-streaming/") }
                .compactMap { anchor -> ScrapedResult? in
                    guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = anchor.first { $0.tag == "h2" || $0.tag == "h3" }?.text ?? anchor["title"]
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(title: title, year: TitleMatch.year(anchor.text), kind: .movie, url: page)
                }
            guard let match = results.bestMatch(for: context) else { continue }
            let page = try await text(match.url)
            var links: [HosterLink] = []
            for pattern in [#"initialSrc\s*=\s*['"]([^'"]+)['"]"#, #"hls_url\s*:\s*['"]([^'"]+)['"]"#] {
                for capture in AnimeHTML.captures(pattern, in: page) {
                    guard capture[1].contains(".m3u8"),
                          let stream = ProviderNetwork.absolute(capture[1], relativeTo: match.url) else { continue }
                    links.append(HosterLink(name: "GuardaFlix HLS", url: stream, referer: match.url, isDirect: true))
                }
            }
            let document = AnimeHTML.parse(page)
            links += document.all { $0.tag == "iframe" && (!$0["data-src"].isEmpty || !$0["src"].isEmpty) }
                .compactMap { frame -> HosterLink? in
                    let raw = frame["data-src"].isEmpty ? frame["src"] : frame["data-src"]
                    guard let embed = ProviderNetwork.absolute(raw, relativeTo: match.url) else { return nil }
                    return HosterLink(name: embed.host ?? "Server", url: embed, referer: match.url)
                }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - CB01

/// Link-table site: streaming rows point at MixDrop directly or at a
/// StayOnline/uprot shortener that has to be unwrapped first.
struct CB01PlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "cb01" }
    var displayName: String { "CB01" }
    var audioLanguage: String { "it" }
    var baseURL: URL { URL(string: "https://cb01uno.homes/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let isSeries = context.request.media.kind == .series
            let search = try await html(url(isSeries ? "serietv/" : "", query: ["s": query]))
            let results = search.all { $0.hasClass("mp-post") }.compactMap { card -> ScrapedResult? in
                guard let anchor = card.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let title = card.first { $0.tag == "h2" || $0.tag == "h3" }?.text ?? anchor.text
                return ScrapedResult(
                    title: title,
                    year: TitleMatch.year(title),
                    kind: isSeries ? .series : .movie,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }
            let document = try await html(match.url)

            var anchors: [AnimeHTML] = []
            if let episode = context.request.episode {
                guard let wrap = document.all({ $0.hasClass("sp-wrap") }).first(where: { node in
                    let head = node.first { $0.hasClass("sp-head") }?.text ?? ""
                    return head.range(of: "stagione\\s+\(episode.seasonNumber)\\b", options: [.regularExpression, .caseInsensitive]) != nil
                }) else { continue }
                guard let line = wrap.all({ $0.tag == "p" }).first(where: { node in
                    AnimeHTML.captures(#"(\d+)[x×](\d+)"#, in: node.text).first.flatMap { Int($0[2]) } == episode.number
                }) else { continue }
                anchors = line.all { $0.tag == "a" && !$0["href"].isEmpty }
            } else {
                anchors = document.all { $0.tag == "table" && $0.hasClass("tableinside") }
                    .flatMap { $0.all { $0.tag == "a" && !$0["href"].isEmpty } }
            }

            var links: [HosterLink] = []
            for anchor in anchors {
                let label = anchor.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = label.lowercased()
                guard name.contains("mixdrop") || name.contains("maxstream") else { continue }
                guard let target = ProviderNetwork.absolute(anchor["href"], relativeTo: match.url) else { continue }
                if let resolved = try? await unwrap(target), !links.contains(where: { $0.url == resolved }) {
                    links.append(HosterLink(name: label.isEmpty ? "CB01" : label, url: resolved, referer: match.url))
                }
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    /// StayOnline hands out the hoster URL over ajax; uprot hides it in two
    /// base64 blobs on its `/mse/` page.
    private func unwrap(_ link: URL) async throws -> URL {
        let value = link.absoluteString
        if value.contains("stayonline.pro") {
            guard let identifier = AnimeHTML.captures(#"/l/([A-Za-z0-9]+)"#, in: value).first?[1] else { return link }
            let endpoint = try url("https://stayonline.pro/ajax/linkEmbedView.php")
            let payload = try await jsonObject(
                endpoint,
                referer: URL(string: "https://stayonline.pro/"),
                form: ["id": identifier, "ref": ""]
            )
            guard (payload["status"] as? String)?.lowercased() == "success",
                  let data = payload["data"] as? [String: Any],
                  let target = data["value"] as? String,
                  let resolved = ProviderNetwork.absolute(target, relativeTo: link) else { return link }
            return try await unwrap(resolved)
        }
        if value.contains("uprot.net") {
            let page = try await text(
                ProviderNetwork.absolute(value.replacingOccurrences(of: "/msf/", with: "/mse/"), relativeTo: link) ?? link,
                referer: link
            )
            let base = AnimeHTML.captures(#"decodedBaseUrl\s*=\s*atob\(["']([^"']+)["']\)"#, in: page).first?[1]
            let tail = AnimeHTML.captures(#"decodedEncryptedVal\s*=\s*atob\(["']([^"']+)["']\)"#, in: page).first?[1]
            guard let base, let tail,
                  let decodedBase = Self.base64(base), let decodedTail = Self.base64(tail),
                  let resolved = ProviderNetwork.absolute(decodedBase + decodedTail, relativeTo: link) else { return link }
            return resolved
        }
        return link
    }

    private static func base64(_ value: String) -> String? {
        var padded = value
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - AnimeUnity

/// JSON archive search, then the `video-player` element that carries the
/// episode table and a Vixcloud embed url.
struct AnimeUnityPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "animeunity" }
    var displayName: String { "AnimeUnity" }
    var audioLanguage: String { "it" }
    var baseURL: URL { URL(string: "https://www.animeunity.so/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        let wantsMovie = context.request.media.kind == .movie
        let episodeNumber = wantsMovie ? 1 : (context.continuousEpisodeNumber ?? 1)

        for query in TitleMatch.queries(for: context) {
            // The archive page seeds the session cookie and CSRF token.
            let archive = try await text(url("archivio"))
            let token = AnimeHTML.captures(#"name="csrf-token"\s+content="([^"]+)""#, in: archive).first?[1] ?? ""
            let payload: [String: Any] = [
                "title": query, "type": false, "year": false, "order": false,
                "status": false, "genres": false, "offset": 0, "dubbed": false, "season": false,
            ]
            let response = try await jsonObject(
                url("archivio/get-animes"),
                referer: try url("archivio"),
                headers: ["X-CSRF-TOKEN": token, "Content-Type": "application/json"],
                body: try JSONSerialization.data(withJSONObject: payload)
            )
            let records = response["records"] as? [[String: Any]] ?? []
            let match = records.first { record in
                let type = record["type"] as? String ?? ""
                guard wantsMovie == type.lowercased().contains("movie") else { return false }
                let names = [record["title_eng"], record["title"], record["title_it"]].compactMap { $0 as? String }
                return names.contains { TitleMatch.matches($0, year: record["date"] as? Int, context: context) }
            }
            guard let match,
                  let animeID = match["id"] as? Int,
                  let slug = match["slug"] as? String else { continue }

            let detail = try await html(url("anime/\(animeID)-\(slug)"))
            guard let player = detail.first({ $0.tag == "video-player" }) else { continue }
            var embed = player["embed_url"]
            if episodeNumber > 1 {
                let raw = player["episodes"].removingPercentEncoding ?? player["episodes"]
                guard let episodes = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]],
                      let target = episodes.first(where: { episode in
                          let number = episode["number"] as? String ?? String(episode["number"] as? Int ?? 0)
                          return Int(number.components(separatedBy: "-")[0]) == episodeNumber
                      }),
                      let episodeID = target["id"].map({ String(describing: $0) }) else { continue }
                embed = try await text(url("embed-url/\(episodeID)")).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let player = ProviderNetwork.absolute(embed, relativeTo: baseURL) else { continue }
            return [HosterLink(name: "Vixcloud", url: player, referer: baseURL, audioLanguage: "it")]
        }
        return []
    }
}

// MARK: - AnimeSaturn

/// The watch page hands Alpine a `watchPage({...})` blob listing internal
/// `/embed/<id>` servers; each embed's playlist payload is XOR-encoded.
struct AnimeSaturnPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "animesaturn" }
    var displayName: String { "AnimeSaturn" }
    var audioLanguage: String { "it" }
    var supportsMovies: Bool { false }
    var baseURL: URL { URL(string: "https://www.animesaturn.net/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation, let episode = context.request.episode else { return [] }
        let number = context.continuousEpisodeNumber ?? episode.number

        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("filter", query: ["key": query]))
            let results = search.all { $0.tag == "a" && $0.hasClass("ac") }.compactMap { anchor -> ScrapedResult? in
                guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let title = anchor["title"].isEmpty ? anchor.text : anchor["title"]
                return ScrapedResult(title: title, year: TitleMatch.year(anchor.text), kind: .series, url: page)
            }
            guard let match = results.bestMatch(for: context) else { continue }
            let slug = match.url.path
                .replacingOccurrences(of: "/episode/", with: "/anime/")
                .split(separator: "/").last.map(String.init) ?? ""
            guard !slug.isEmpty, let watchURL = try? url("anime/\(slug)/ep-\(number)") else { continue }
            let page = try await text(watchURL)
            guard let blob = AnimeHTML.captures(#"watchPage\((\{[\s\S]*?\})\)"#, in: page).first?[1],
                  let data = try? JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any] else { continue }
            let servers = data["servers"] as? [[String: Any]] ?? []
            var embeds = servers.compactMap { server -> (String, URL)? in
                guard let link = server["link"] as? String,
                      let embed = ProviderNetwork.absolute(link, relativeTo: watchURL),
                      embed.path.range(of: #"/embed/\d+"#, options: .regularExpression) != nil else { return nil }
                return (server["name"] as? String ?? "AnimeSaturn", embed)
            }
            if embeds.isEmpty, let initial = data["initialVideoUrl"] as? String,
               let embed = ProviderNetwork.absolute(initial, relativeTo: watchURL),
               embed.path.range(of: #"/embed/\d+"#, options: .regularExpression) != nil {
                embeds = [("AnimeSaturn", embed)]
            }
            let client = client
            let links = embeds.map { name, embed in
                HosterLink(name: name, url: embed, referer: watchURL, audioLanguage: "it", resolveOverride: {
                    try await Self.resolveEmbed(embed, referer: watchURL, client: client)
                })
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    private static func resolveEmbed(_ embed: URL, referer: URL, client: any HTTPClientProtocol) async throws -> PlaybackSource {
        let components = URLComponents(url: embed, resolvingAgainstBaseURL: false)
        var identifier = AnimeHTML.captures(#"/embed/(\d+)"#, in: embed.path).first?[1] ?? ""
        var token = components?.queryItems?.first { $0.name == "token" }?.value ?? ""
        var expires = components?.queryItems?.first { $0.name == "expires" }?.value ?? ""
        if let response = try? await ProviderNetwork.data(client: client, url: embed, referer: referer),
           let page = String(data: response.data, encoding: .utf8),
           let match = AnimeHTML.captures(
               #"window\.__E\s*=\s*\{\s*i\s*:\s*(\d+)\s*,\s*k\s*:\s*"([^"]+)"\s*,\s*e\s*:\s*(\d+)"#,
               in: page
           ).first {
            identifier = match[1]
            token = match[2]
            expires = match[3]
        }
        guard !identifier.isEmpty, !token.isEmpty, let scheme = embed.scheme, let host = embed.host,
              let playlist = URL(string: "\(scheme)://\(host)/embed/\(identifier)/playlist?token=\(ProviderNetwork.encoded(token))&expires=\(ProviderNetwork.encoded(expires))") else {
            throw AppError.noStream
        }
        let response = try await ProviderNetwork.data(client: client, url: playlist, referer: embed, acceptsJSON: true)
        guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let encoded = payload["d"] as? String,
              let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) else { throw AppError.noStream }
        let key = Array(token.utf8)
        let decoded = String(decoding: bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] }, as: UTF8.self)
        guard !decoded.hasPrefix("youtube/"),
              let source = ProviderNetwork.absolute(decoded, relativeTo: embed) else { throw AppError.noStream }
        return PlaybackSource(
            url: source,
            headers: HosterResolver.headers(for: source, referer: embed),
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }
}

// MARK: - GuardaSerie

/// Plays through VixSrc, which is keyed by TMDB id, so the catalogue lookup is
/// only needed when the request has no TMDB id of its own.
struct GuardaSeriePlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "guardaserie" }
    var displayName: String { "GuardaSerie" }
    var audioLanguage: String { "it" }
    var baseURL: URL { URL(string: "https://guarda-serie.ovh/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        var tmdbID = context.request.media.tmdbID
        var playerBase = "https://vixsrc.to"

        if tmdbID == nil {
            for query in TitleMatch.queries(for: context) {
                let search = try await html(url("search", query: ["q": query]))
                let results = search.all { $0.tag == "a" && $0["href"].contains("/detail/") }
                    .compactMap { anchor -> ScrapedResult? in
                        guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                        let title = anchor["title"].isEmpty ? anchor.text : anchor["title"]
                        guard !title.isEmpty else { return nil }
                        return ScrapedResult(
                            title: title,
                            year: TitleMatch.year(anchor.text),
                            kind: anchor["href"].contains("/detail/movie-") ? .movie : .series,
                            url: page
                        )
                    }
                guard let match = results.bestMatch(for: context) else { continue }
                let page = try await text(match.url)
                if let base = AnimeHTML.captures(#"playerBaseURL\s*=\s*"([^"]+)""#, in: page).first?[1] {
                    playerBase = base.replacingOccurrences(of: "\\/", with: "/")
                }
                tmdbID = AnimeHTML.captures(#"tmdbID\s*=\s*(\d+)"#, in: page).first.flatMap { Int($0[1]) }
                    ?? AnimeHTML.captures(#"/detail/(?:tv|movie)-(\d+)"#, in: match.url.absoluteString).first.flatMap { Int($0[1]) }
                if tmdbID != nil { break }
            }
        }
        guard let tmdbID else { return [] }

        let path: String
        switch context.request.media.kind {
        case .movie:
            path = "\(playerBase)/movie/\(tmdbID)"
        case .series:
            guard let episode = context.request.episode else { return [] }
            path = "\(playerBase)/tv/\(tmdbID)/\(episode.seasonNumber)/\(episode.number)"
        }
        guard let player = URL(string: "\(path)?lang=it") else { return [] }
        return [HosterLink(name: "VixSrc", url: player, referer: baseURL, audioLanguage: "it")]
    }
}

// MARK: - StreamingIta

/// DooPlay theme: the detail page exposes a post id, and `doo_player_ajax`
/// returns either an embed or a mirror list.
struct StreamingItaPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "streamingita" }
    var displayName: String { "StreamingITA" }
    var audioLanguage: String { "it" }
    var baseURL: URL { URL(string: "https://streamingita.homes/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.hasClass("result-item") }.compactMap { item -> ScrapedResult? in
                guard let anchor = item.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                return ScrapedResult(
                    title: anchor.text,
                    year: TitleMatch.year(item.text),
                    kind: anchor["href"].contains("/serie") || anchor["href"].contains("/tvshows") ? .series : .movie,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                let show = try await html(match.url)
                guard let row = show.all({ $0.tag == "li" }).first(where: { node in
                    let numbering = node.first { $0.hasClass("numerando") }?.text ?? ""
                    let parts = AnimeHTML.captures(#"(\d+)\s*-\s*(\d+)"#, in: numbering).first
                    return parts.flatMap { Int($0[1]) } == episode.seasonNumber
                        && parts.flatMap { Int($0[2]) } == episode.number
                }), let href = row.first({ $0.tag == "a" && !$0["href"].isEmpty })?["href"],
                    let episodeURL = ProviderNetwork.absolute(href, relativeTo: baseURL) else { continue }
                page = episodeURL
            }

            let document = try await html(page)
            guard let holder = document.first({ !$0["data-post"].isEmpty }) else { continue }
            let post = holder["data-post"]
            let type = document.first { !$0["data-type"].isEmpty }?["data-type"] ?? "movie"
            let numbers = document.all { !$0["data-nume"].isEmpty }.compactMap { Int($0["data-nume"]) }

            var links: [HosterLink] = []
            for number in (numbers.isEmpty ? [1] : numbers).prefix(4) {
                guard let payload = try? await jsonObject(
                    url("wp-admin/admin-ajax.php"),
                    referer: page,
                    form: ["action": "doo_player_ajax", "post": post, "nume": String(number), "type": type]
                ), let raw = payload["embed_url"] as? String,
                    let embed = ProviderNetwork.absolute(raw.replacingOccurrences(of: "\\/", with: "/"), relativeTo: page)
                else { continue }
                // The second slot usually points at a mirror list rather than a player.
                if let mirrors = try? await html(embed, referer: page) {
                    let entries = mirrors.all { $0.tag == "li" && !$0["data-link"].isEmpty }
                        .filter { !$0.hasClass("fullhd") && !$0.text.lowercased().contains("4k") }
                        .compactMap { node -> HosterLink? in
                            guard let target = ProviderNetwork.absolute(node["data-link"], relativeTo: embed) else { return nil }
                            let label = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            return HosterLink(name: label.isEmpty ? "Server" : label, url: target, referer: embed, audioLanguage: "it")
                        }
                    if !entries.isEmpty {
                        links += entries
                        continue
                    }
                }
                links.append(HosterLink(name: embed.host ?? "Server \(number)", url: embed, referer: page, audioLanguage: "it"))
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - AnimeWorld

/// Each episode anchor carries both an episode id and a server-specific link
/// id; `api/episode/info` turns the latter into a playable grabber url.
struct AnimeWorldPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "animeworld" }
    var displayName: String { "AnimeWorld" }
    var audioLanguage: String { "it" }
    var baseURL: URL { URL(string: "https://www.animeworld.ac/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        let number = context.request.media.kind == .movie ? 1 : (context.continuousEpisodeNumber ?? 1)

        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("search", query: [
                "keyword": query.replacingOccurrences(of: " ", with: "+"), "page": "1",
            ]))
            let results = search.all { $0.hasClass("item") }.compactMap { item -> ScrapedResult? in
                guard let anchor = item.first({ $0.tag == "a" && $0.hasClass("name") })
                    ?? item.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                    let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                return ScrapedResult(title: anchor.text, year: TitleMatch.year(item.text), url: page)
            }
            guard let match = results.bestMatch(for: context),
                  let showID = match.url.absoluteString.components(separatedBy: "/").last else { continue }

            let detail = try await html(url("play/\(showID)"))
            let servers = detail.all { $0.hasClass("server") }
            var links: [HosterLink] = []
            for server in servers {
                let anchors = server.all { $0.tag == "a" && !$0["data-episode-id"].isEmpty }
                let anchor = anchors.first { node in
                    Int(node.text.trimmingCharacters(in: .whitespaces)) == number
                        || Int(node["data-episode-num"]) == number
                } ?? (number == 1 ? anchors.first : nil)
                guard let anchor, !anchor["data-id"].isEmpty else { continue }
                let linkID = anchor["data-id"]
                let name = server["data-id"] == "8" ? "Streamtape" : "AnimeWorld Server"
                guard let endpoint = try? url("api/episode/info", query: ["id": linkID, "alt": "0"]) else { continue }
                let client = client
                let referer = try url("play/\(showID)")
                links.append(HosterLink(name: name, url: endpoint, referer: referer, audioLanguage: "it", resolveOverride: {
                    let payload = try await ProviderNetwork.data(
                        client: client, url: endpoint, referer: referer, acceptsJSON: true
                    )
                    guard let object = try JSONSerialization.jsonObject(with: payload.data) as? [String: Any],
                          let grabber = object["grabber"] as? String,
                          let source = ProviderNetwork.absolute(grabber, relativeTo: referer) else { throw AppError.noStream }
                    if HosterResolver.isDirect(source) {
                        return PlaybackSource(
                            url: source,
                            headers: HosterResolver.headers(for: source, referer: referer),
                            subtitles: [],
                            preferredPeakBitRate: nil
                        )
                    }
                    return try await HosterResolver(client: client).resolve(source, referer: referer)
                }))
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}
