import Foundation

/// Spanish-language BetterStreamflix providers ported from the Android catalogue.

// MARK: - Fanpelis

/// REST catalogue: search returns post ids, and `player` returns the embed list.
struct FanpelisPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "fanpelis" }
    var displayName: String { "Fanpelis" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://fanpelis.to/api/rest/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let response = try await jsonObject(url("search", query: [
                "query": query, "page": "1", "post_type": "movies,tvshows,animes", "posts_per_page": "16",
            ]))
            let posts = ((response["data"] as? [String: Any])?["posts"] as? [[String: Any]]) ?? []
            let wantsMovie = context.request.media.kind == .movie
            let match = posts.first { post in
                let type = post["type"] as? String ?? ""
                guard wantsMovie == (type == "movies") else { return false }
                let title = post["title"] as? String ?? ""
                let year = TitleMatch.year(post["release_date"] as? String ?? post["year"].map { String(describing: $0) })
                return TitleMatch.matches(title, year: year, context: context)
            }
            guard let match, let postID = Self.identifier(match["id"]) else { continue }

            var playerID = postID
            if let episode = context.request.episode {
                let response = try await jsonObject(url("episodes", query: ["post_id": postID]))
                let episodes = response["data"] as? [[String: Any]] ?? []
                guard let target = episodes.first(where: { entry in
                    Self.number(entry["season"]) == episode.seasonNumber
                        && Self.number(entry["episode"]) == episode.number
                }), let identifier = Self.identifier(target["id"]) else { continue }
                playerID = identifier
            }

            let player = try await jsonObject(url("player", query: ["post_id": playerID, "_any": "1"]))
            let embeds = ((player["data"] as? [String: Any])?["embeds"] as? [[String: Any]]) ?? []
            let links = embeds.enumerated().compactMap { index, embed -> HosterLink? in
                guard let raw = embed["url"] as? String,
                      let target = ProviderNetwork.absolute(raw, relativeTo: baseURL) else { return nil }
                return HosterLink(
                    name: target.host ?? "Server \(index + 1)",
                    url: target,
                    referer: URL(string: "https://fanpelis.to/"),
                    audioLanguage: "es"
                )
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    private static func identifier(_ value: Any?) -> String? {
        if let number = value as? Int { return String(number) }
        if let string = value as? String, !string.isEmpty { return string }
        return nil
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

// MARK: - CineCalidad

/// DooPlay theme whose player options carry the embed url inline.
struct CineCalidadPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "cinecalidad" }
    var displayName: String { "CineCalidad" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://www.cinecalidad.am/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("page/1", query: ["s": query]))
            let results = search.all { $0.tag == "article" && $0["id"].hasPrefix("post-") }
                .compactMap { article -> ScrapedResult? in
                    guard let anchor = article.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                          let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = article.first { $0.tag == "h2" || $0.tag == "h3" }?.text ?? anchor["title"]
                    return ScrapedResult(title: title, year: TitleMatch.year(article.text), url: page)
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
            let links = document.all { $0.tag == "li" && !$0["data-option"].isEmpty }
                .filter { !$0.text.lowercased().contains("trailer") }
                .compactMap { option -> HosterLink? in
                    guard let embed = ProviderNetwork.absolute(option["data-option"], relativeTo: page) else { return nil }
                    let label = option.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return HosterLink(
                        name: label.isEmpty ? (embed.host ?? "Server") : label,
                        url: embed,
                        referer: page,
                        audioLanguage: "es"
                    )
                }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - FlixLatam

/// DooPlay variant that renders the active player in a `div.pframe` iframe.
struct FlixLatamPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "flixlatam" }
    var displayName: String { "FlixLatam" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://flixlatam.com/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("search", query: ["s": query]))
            let results = search.all { $0.tag == "article" }.compactMap { article -> ScrapedResult? in
                guard let anchor = article.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let title = article.first { $0.hasClass("title") }?.text ?? anchor.text
                return ScrapedResult(
                    title: title,
                    year: TitleMatch.year(article.text),
                    kind: anchor["href"].contains("/serie") || anchor["href"].contains("/tvshows") ? .series : .movie,
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
            var links = document.all { $0.hasClass("pframe") || $0.hasClass("dooplay_player") }
                .flatMap { embedLinks(in: $0, page: page, named: "FlixLatam") }
            if links.isEmpty { links = embedLinks(in: document, page: page, named: "FlixLatam") }
            links = links.filter { !$0.url.absoluteString.contains("/vidurl/") }
            if !links.isEmpty { return links.map { link in
                HosterLink(name: link.name, url: link.url, referer: link.referer, audioLanguage: "es")
            } }
        }
        return []
    }
}

// MARK: - SeriesFlix

/// Series only. Server buttons hold base64 urls grouped by audio language.
struct SeriesFlixPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "seriesflix" }
    var displayName: String { "SeriesFlix" }
    var audioLanguage: String { "es" }
    var supportsMovies: Bool { false }
    var baseURL: URL { URL(string: "https://seriesflixhd.team/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard let episode = context.request.episode else { return [] }
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.hasClass("TPost") }.compactMap { card -> ScrapedResult? in
                guard let anchor = card.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let title = card.first { $0.hasClass("title") || $0.tag == "h2" || $0.tag == "h3" }?.text ?? anchor.text
                return ScrapedResult(title: title, year: TitleMatch.year(card.text), kind: .series, url: page)
            }
            guard let match = results.bestMatch(for: context) else { continue }

            let show = try await html(match.url)
            guard let seasonHref = show.all({ $0.tag == "a" && $0["href"].contains("/temporada/") })
                .first(where: { anchor in
                    AnimeHTML.captures(#"Temporada\s+(\d+)"#, in: anchor.text).first.flatMap { Int($0[1]) } == episode.seasonNumber
                        || AnimeHTML.captures(#"-(\d+)/?$"#, in: anchor["href"]).first.flatMap { Int($0[1]) } == episode.seasonNumber
                })?["href"],
                let seasonURL = ProviderNetwork.absolute(seasonHref, relativeTo: baseURL) else { continue }

            let season = try await html(seasonURL)
            guard let row = season.all({ $0.tag == "tr" }).first(where: { node in
                Int(node.first { $0.hasClass("Num") }?.text.trimmingCharacters(in: .whitespaces) ?? "") == episode.number
            }), let href = row.first({ $0.tag == "a" && !$0["href"].isEmpty })?["href"],
                let episodeURL = ProviderNetwork.absolute(href, relativeTo: baseURL) else { continue }

            let document = try await html(episodeURL)
            let links = document.all { !$0["data-url"].isEmpty && $0.hasClass("Button") }
                .compactMap { button -> HosterLink? in
                    guard let decoded = Self.decode(button["data-url"]),
                          let target = Self.unwrap(decoded, relativeTo: episodeURL) else { return nil }
                    let language = button.ancestor { $0.hasClass("drpdn") }?
                        .first { $0.tag == "button" }?.text.lowercased() ?? ""
                    return HosterLink(
                        name: "\(target.host ?? "Server")\(language.contains("sub") ? " SUB" : "")",
                        url: target,
                        referer: episodeURL,
                        audioLanguage: language.contains("ingl") ? "en" : "es"
                    )
                }
            if !links.isEmpty { return links }
        }
        return []
    }

    private static func decode(_ value: String) -> String? {
        var padded = value.trimmingCharacters(in: .whitespacesAndNewlines)
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8), decoded.hasPrefix("http") else { return nil }
        return decoded
    }

    /// Some buttons wrap the hoster in a `?url=` redirector.
    private static func unwrap(_ value: String, relativeTo base: URL) -> URL? {
        guard let url = ProviderNetwork.absolute(value, relativeTo: base) else { return nil }
        guard let inner = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value else { return url }
        return ProviderNetwork.absolute(inner, relativeTo: base) ?? url
    }
}

// MARK: - SeriesTurcas

/// Series only. Episodes live on the show page and each carries a download-style
/// list of hoster links.
struct SeriesTurcasPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "seriesturcas" }
    var displayName: String { "SeriesTurcas" }
    var audioLanguage: String { "es" }
    var supportsMovies: Bool { false }
    var baseURL: URL { URL(string: "https://kaj.seriesturcastv.to/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard let episode = context.request.episode else { return [] }
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.hasClass("item") }.compactMap { item -> ScrapedResult? in
                guard let anchor = item.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let title = item.first { $0.hasClass("title") }?.text ?? anchor["title"]
                guard !title.isEmpty else { return nil }
                return ScrapedResult(title: title, year: TitleMatch.year(item.text), kind: .series, url: page)
            }
            guard let match = results.bestMatch(for: context) else { continue }

            let show = try await html(match.url)
            guard let anchor = show.all({ $0.tag == "a" && $0.hasClass("episod") })
                .first(where: { node in
                    AnimeHTML.captures(#"(\d+)"#, in: node.text).first.flatMap { Int($0[1]) } == episode.number
                }), let episodeURL = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { continue }

            let document = try await html(episodeURL)
            let links = document.all { $0.hasClass("dl-contenti") }
                .flatMap { $0.all { $0.tag == "a" && $0["href"].hasPrefix("http") } }
                .enumerated()
                .compactMap { index, node -> HosterLink? in
                    guard let target = ProviderNetwork.absolute(node["href"], relativeTo: episodeURL) else { return nil }
                    return HosterLink(
                        name: "\(target.host ?? "Server") \(index + 1)",
                        url: target,
                        referer: episodeURL,
                        audioLanguage: "es"
                    )
                }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - LaCartoons

/// Cartoon catalogue with a plain `?Titulo=` search and iframe players.
struct LaCartoonsPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "lacartoons" }
    var displayName: String { "LaCartoons" }
    var audioLanguage: String { "es" }
    var supportsMovies: Bool { false }
    var baseURL: URL { URL(string: "https://www.lacartoons.com/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation, let episode = context.request.episode else { return [] }
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["Titulo": query]))
            let results = search.all { $0.tag == "a" && $0["href"].contains("serie") }
                .compactMap { anchor -> ScrapedResult? in
                    guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = anchor.first { $0.tag == "h5" || $0.tag == "h4" || $0.tag == "p" }?.text ?? anchor.text
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(title: title, kind: .series, url: page)
                }
            guard let match = results.bestMatch(for: context) else { continue }

            let show = try await html(match.url)
            guard let anchor = show.all({ $0.tag == "a" && $0["href"].contains("capitulo") })
                .first(where: { node in
                    AnimeHTML.captures(#"Capitulo\s*(\d+)"#, in: node.text).first.flatMap { Int($0[1]) } == episode.number
                }), let episodeURL = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { continue }

            let document = try await html(episodeURL)
            let links = embedLinks(in: document, page: episodeURL, named: "LaCartoons")
                .filter { !$0.url.absoluteString.contains("about:") }
            if !links.isEmpty {
                return links.map { HosterLink(name: $0.name, url: $0.url, referer: episodeURL, audioLanguage: "es") }
            }
        }
        return []
    }
}

// MARK: - Animefenix

/// The watch page publishes its mirrors as a `var videos = [[name, url], …]`
/// array; older mirrors fall back to plain iframes.
struct AnimefenixPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "animefenix" }
    var displayName: String { "Animefenix" }
    var audioLanguage: String { "es" }
    var supportsMovies: Bool { false }
    var baseURL: URL { URL(string: "https://animefenix.live/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation, let episode = context.request.episode else { return [] }
        let number = context.continuousEpisodeNumber ?? episode.number
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("directorio", query: ["q": query, "p": "1"]))
            let results = search.all { $0.tag == "a" && $0["href"].contains("/anime/") }
                .compactMap { anchor -> ScrapedResult? in
                    guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = anchor["title"].isEmpty ? anchor.text : anchor["title"]
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(title: title, kind: .series, url: page)
                }
            guard let match = results.bestMatch(for: context) else { continue }
            let slug = match.url.path.split(separator: "/").last.map(String.init) ?? ""
            guard !slug.isEmpty, let watchURL = try? url("ver/\(slug)-\(number)") else { continue }
            guard let page = try? await text(watchURL) else { continue }

            var links: [HosterLink] = []
            if let array = Self.jsArray(named: "var videos", in: page),
               let entries = try? JSONSerialization.jsonObject(with: Data(array.utf8)) as? [[Any]] {
                for (index, entry) in entries.enumerated() {
                    let label = entry.first as? String ?? "Server \(index + 1)"
                    guard entry.count > 1, let raw = entry[1] as? String,
                          let target = ProviderNetwork.absolute(raw, relativeTo: watchURL) else { continue }
                    links.append(HosterLink(name: label, url: target, referer: watchURL, audioLanguage: "es"))
                }
            }
            if links.isEmpty {
                links = embedLinks(in: AnimeHTML.parse(page), page: watchURL, named: "Animefenix")
                    .map { HosterLink(name: $0.name, url: $0.url, referer: watchURL, audioLanguage: "es") }
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    /// Reads a bracketed JS array literal, tracking nesting and quoting.
    static func jsArray(named marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let start = source.range(of: "[", range: markerRange.upperBound..<source.endIndex)?.lowerBound else {
            return nil
        }
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 {
                    let literal = String(source[start...index])
                    return literal.replacingOccurrences(of: "\\/", with: "/")
                        .replacingOccurrences(of: "'", with: "\"")
                }
            }
            index = source.index(after: index)
        }
        return nil
    }
}

// MARK: - AnimeFlv

/// Episode pages hide their mirrors behind an encrypted `data-encrypt` blob that
/// `/flv` expands into hex-encoded embed urls.
struct AnimeFlvPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "animeflv" }
    var displayName: String { "AnimeFLV" }
    var audioLanguage: String { "es" }
    var supportsMovies: Bool { false }
    var baseURL: URL { URL(string: "https://www.animeflv.vc/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation, let episode = context.request.episode else { return [] }
        let number = context.continuousEpisodeNumber ?? episode.number

        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("animes", query: ["buscar": query, "pag": "1"]))
            let results = search.all { $0.tag == "a" && $0["href"].contains("/anime/") }
                .compactMap { anchor -> ScrapedResult? in
                    guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = anchor.text.isEmpty
                        ? anchor["title"]
                            .replacingOccurrences(of: "Ver Anime ", with: "")
                            .replacingOccurrences(of: " Online Gratis", with: "")
                        : anchor.text
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(title: title, kind: .series, url: page)
                }
            guard let match = results.bestMatch(for: context) else { continue }
            let slug = match.url.path.split(separator: "/").last.map(String.init) ?? ""
            guard !slug.isEmpty else { continue }

            // The show page lists every episode as ["number","hasThumb","code"].
            let show = try await text(match.url)
            let entries = AnimeHTML.captures(#"\["(\d+)","(\d+)","([^"]*)"\]"#, in: show)
            guard let entry = entries.first(where: { Int($0[1]) == number }) else { continue }
            let suffix = entry[3].isEmpty ? "" : "-\(entry[3])"
            guard let episodeURL = try? url("ver/\(slug)-\(number)\(suffix)") else { continue }

            let page = try await html(episodeURL)
            guard let encrypted = page.first({ !$0["data-encrypt"].isEmpty })?["data-encrypt"] else { continue }
            let options = try await text(
                url("flv"),
                referer: episodeURL,
                headers: ["X-Requested-With": "XMLHttpRequest"],
                form: ["acc": "opt", "i": encrypted]
            )
            let links = AnimeHTML.parse(options).all { $0.tag == "li" && !$0["encrypt"].isEmpty }
                .compactMap { node -> HosterLink? in
                    guard let decoded = Self.hex(node["encrypt"]),
                          let target = ProviderNetwork.absolute(decoded, relativeTo: episodeURL) else { return nil }
                    let name = node["title"].isEmpty ? node.text : node["title"]
                    return HosterLink(
                        name: name.replacingOccurrences(of: "Opción ", with: "").trimmingCharacters(in: .whitespaces),
                        url: target,
                        referer: episodeURL,
                        audioLanguage: "ja"
                    )
                }
            if !links.isEmpty { return links }
        }
        return []
    }

    private static func hex(_ value: String) -> String? {
        let characters = Array(value)
        guard !characters.isEmpty, characters.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - JKAnime

/// CSRF-guarded ajax search, then the episode page's inline player array.
struct JKAnimePlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "jkanime" }
    var displayName: String { "JKAnime" }
    var audioLanguage: String { "ja" }
    var baseURL: URL { URL(string: "https://jkanime.net/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        let number = context.request.media.kind == .movie ? 1 : (context.continuousEpisodeNumber ?? 1)
        let wantsMovie = context.request.media.kind == .movie

        let home = try await text(url(""))
        let token = AnimeHTML.captures(#"name="csrf-token"\s+content="([^"]+)""#, in: home).first?[1] ?? ""

        for query in TitleMatch.queries(for: context) {
            let raw = try await text(
                url("ajax_search"),
                referer: baseURL,
                headers: ["X-CSRF-TOKEN": token, "X-Requested-With": "XMLHttpRequest"],
                form: ["q": query, "_token": token]
            )
            guard let rows = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]] else { continue }
            let match = rows.first { row in
                let type = row["type"] as? String ?? ""
                guard wantsMovie == type.lowercased().contains("pelicula") else { return false }
                return TitleMatch.matches(row["title"] as? String ?? "", context: context)
            }
            guard let slug = match?["slug"] as? String, !slug.isEmpty,
                  let episodeURL = try? url("\(slug)/\(number)/") else { continue }

            let page = try await text(episodeURL)
            var links: [HosterLink] = []
            for capture in AnimeHTML.captures(#"video\[(\d+)\]\s*=\s*['"][^'"]*?src=['\\"]+([^'"\\ ]+)"#, in: page) {
                guard let target = ProviderNetwork.absolute(
                    HTMLPayloadParser.decodeEntities(capture[2]), relativeTo: episodeURL
                ) else { continue }
                links.append(HosterLink(name: "JKPlayer \(capture[1])", url: target, referer: episodeURL))
            }
            if let array = AnimefenixPlaybackProvider.jsArray(named: "var servers", in: page),
               let entries = try? JSONSerialization.jsonObject(with: Data(array.utf8)) as? [[String: Any]] {
                for entry in entries {
                    guard let name = entry["server"] as? String,
                          let remote = entry["remote"] as? String,
                          let data = Data(base64Encoded: remote, options: .ignoreUnknownCharacters),
                          let decoded = String(data: data, encoding: .utf8),
                          let target = ProviderNetwork.absolute(decoded, relativeTo: episodeURL) else { continue }
                    links.append(HosterLink(name: name, url: target, referer: episodeURL))
                }
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - TioAnime

/// Watch pages expose `var videos = [[name, url], …]`.
struct TioAnimePlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "tioanime" }
    var displayName: String { "TioAnime" }
    var audioLanguage: String { "ja" }
    var baseURL: URL { URL(string: "https://tioanime.top/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        let number = context.request.media.kind == .movie ? 1 : (context.continuousEpisodeNumber ?? 1)

        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("directorio", query: ["q": query]))
            let results = search.all { $0.tag == "a" && $0["href"].contains("/anime/") }
                .compactMap { anchor -> ScrapedResult? in
                    guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = anchor.first { $0.tag == "h3" }?.text ?? anchor["title"]
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(title: title, url: page)
                }
            guard let match = results.bestMatch(for: context) else { continue }
            let slug = match.url.path.split(separator: "/").last.map(String.init) ?? ""
            guard !slug.isEmpty, let episodeURL = try? url("ver/\(slug)-\(number)") else { continue }
            guard let page = try? await text(episodeURL),
                  let array = AnimefenixPlaybackProvider.jsArray(named: "var videos", in: page),
                  let entries = try? JSONSerialization.jsonObject(with: Data(array.utf8)) as? [[Any]] else { continue }
            let links = entries.enumerated().compactMap { index, entry -> HosterLink? in
                let label = entry.first as? String ?? "Server \(index + 1)"
                guard entry.count > 1, let raw = entry[1] as? String,
                      let target = ProviderNetwork.absolute(raw, relativeTo: episodeURL) else { return nil }
                return HosterLink(name: label, url: target, referer: episodeURL)
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - AnimeAv1

/// SvelteKit site: `__data.json` stores flattened nodes, so servers are reached
/// by following index pointers into the episode's data array.
struct AnimeAv1PlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "animeav1" }
    var displayName: String { "AnimeAV1" }
    var audioLanguage: String { "ja" }
    var supportsMovies: Bool { false }
    var baseURL: URL { URL(string: "https://animeav1.com/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation, let episode = context.request.episode else { return [] }
        let number = context.continuousEpisodeNumber ?? episode.number

        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("catalogo", query: ["search": query]))
            let results = search.all { $0.tag == "a" && $0["href"].contains("/media/") }
                .compactMap { anchor -> ScrapedResult? in
                    guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = anchor.first { $0.tag == "h3" }?.text ?? anchor["title"]
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(title: title, url: page)
                }
            guard let match = results.bestMatch(for: context) else { continue }
            let slug = match.url.path.replacingOccurrences(of: "/media/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !slug.isEmpty, let payload = try? await jsonObject(url("media/\(slug)/\(number)/__data.json")) else { continue }

            guard let nodes = payload["nodes"] as? [[String: Any]] else { continue }
            guard let node = nodes.first(where: { node in
                guard let data = node["data"] as? [Any], let head = data.first as? [String: Any] else { return false }
                return head["media"] != nil && head["episode"] != nil && head["embeds"] != nil
            }), let data = node["data"] as? [Any], let head = data.first as? [String: Any],
                let embedsIndex = head["embeds"] as? Int, embedsIndex < data.count,
                let embeds = data[embedsIndex] as? [String: Any] else { continue }

            var links: [HosterLink] = []
            for (key, language) in [("SUB", "ja"), ("DUB", "es")] {
                guard let listIndex = embeds[key] as? Int, listIndex >= 0, listIndex < data.count,
                      let list = data[listIndex] as? [Any] else { continue }
                for pointer in list.compactMap({ $0 as? Int }) where pointer >= 0 && pointer < data.count {
                    guard let entry = data[pointer] as? [String: Any],
                          let nameIndex = entry["server"] as? Int, let urlIndex = entry["url"] as? Int,
                          nameIndex < data.count, urlIndex < data.count,
                          let name = data[nameIndex] as? String, let raw = data[urlIndex] as? String else { continue }
                    let lowered = name.lowercased()
                    guard !lowered.contains("mega"), !lowered.contains("mp4upload"), !lowered.contains("byse") else { continue }
                    guard let target = ProviderNetwork.absolute(raw, relativeTo: baseURL) else { continue }
                    links.append(HosterLink(
                        name: "\(name) (\(key))",
                        url: target,
                        referer: match.url,
                        audioLanguage: language
                    ))
                }
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - CuevanaEu

/// JSON catalogue: `/wp-api/v1` serves search, the episode list and the embeds.
struct CuevanaEuPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "cuevanaeu" }
    var displayName: String { "Cuevana" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://cuevana3.gs/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        let wantsMovie = context.request.media.kind == .movie
        for query in TitleMatch.queries(for: context) {
            let search = try await jsonObject(url("wp-api/v1/search", query: [
                "q": query, "page": "1", "postType": "any", "postsPerPage": "24",
            ]))
            guard let post = Self.list(search, "posts").first(where: { post in
                guard wantsMovie == ((post["type"] as? String) == "movies") else { return false }
                let year = (post["years"] as? [Int])?.first ?? TitleMatch.year(post["release_date"] as? String)
                return [post["title"] as? String, post["original_title"] as? String]
                    .compactMap { $0 }
                    .contains { TitleMatch.matches($0, year: year, context: context) }
            }), let postID = post["_id"] as? Int else { continue }

            var playerID = postID
            if let episode = context.request.episode {
                let list = try await jsonObject(url("wp-api/v1/single/episodes/list", query: [
                    "_id": String(postID), "season": String(episode.seasonNumber),
                    "page": "1", "postsPerPage": "100",
                ]))
                guard let entry = Self.list(list, "posts").first(where: {
                    ($0["season_number"] as? Int) == episode.seasonNumber
                        && ($0["episode_number"] as? Int) == episode.number
                }), let identifier = entry["_id"] as? Int else { continue }
                playerID = identifier
            }

            let player = try await jsonObject(url("wp-api/v1/player", query: [
                "postId": String(playerID), "demo": "0",
            ]))
            let links = Self.list(player, "embeds").compactMap { embed -> HosterLink? in
                guard let raw = embed["url"] as? String,
                      let target = ProviderNetwork.absolute(raw, relativeTo: baseURL) else { return nil }
                let parts = [
                    embed["server"] as? String ?? target.host,
                    embed["lang"] as? String,
                    embed["quality"] as? String,
                ].compactMap { $0 }.filter { !$0.isEmpty }
                return HosterLink(
                    name: parts.isEmpty ? "Server" : parts.joined(separator: " | "),
                    url: target,
                    referer: baseURL,
                    audioLanguage: "es"
                )
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    private static func list(_ payload: [String: Any], _ key: String) -> [[String: Any]] {
        ((payload["data"] as? [String: Any])?[key] as? [[String: Any]]) ?? []
    }
}

// MARK: - Latanime

/// Anime catalogue whose play buttons carry base64 embed urls.
struct LatanimePlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "latanime" }
    var displayName: String { "Latanime" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://latanime.org/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("buscar", query: ["q": query]))
            let results = search.all { $0.tag == "a" && $0["href"].contains("/anime/") }
                .compactMap { anchor -> ScrapedResult? in
                    guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = anchor.first { $0.tag == "h3" }?.text ?? anchor["title"]
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(title: title, url: page)
                }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                let number = context.continuousEpisodeNumber ?? episode.number
                let detail = try await html(match.url)
                guard let anchor = detail.first({ node in
                    guard node.tag == "a", !node["href"].isEmpty,
                          let capture = AnimeHTML.captures(#"capitulo\s*(\d+)"#, in: node.text).first else { return false }
                    return Int(capture[1]) == number
                }), let resolved = ProviderNetwork.absolute(anchor["href"], relativeTo: match.url) else { continue }
                page = resolved
            }

            let document = try await html(page)
            let links = document.all { !$0["data-player"].isEmpty }
                .compactMap { button -> HosterLink? in
                    guard let decoded = SpanishScraping.base64Text(button["data-player"]),
                          let target = ProviderNetwork.absolute(decoded, relativeTo: page) else { return nil }
                    let label = button.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return HosterLink(
                        name: label.isEmpty ? (target.host ?? "Server") : label,
                        url: target,
                        referer: page,
                        audioLanguage: "es"
                    )
                }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - Doramasflix

/// App Router site: the catalogue is html, but stream links come from Next.js
/// server actions that answer with a flight stream.
struct DoramasflixPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "doramasflix" }
    var displayName: String { "Doramasflix" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://doramasflix.in/")! }

    private static let movieLinksAction = "40a81e120660afa2566d1235e6a4c05b1114d87a48"
    private static let episodeLinksAction = "4042b6ff7262141961145bdab7008e4c92323e054d"
    private static let episodesAction = "40c389f001a72f0eb6ae05c14b824cb0d8d17926c5"

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        let section = context.request.media.kind == .movie ? "peliculas-online" : "doramas-online"
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("buscar", query: ["q": query, "page": "1"]))
            let results = search.all { $0.tag == "a" && $0["href"].contains("/\(section)/") }
                .compactMap { anchor -> ScrapedResult? in
                    guard let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = anchor.first { $0.tag == "img" }?["alt"].nonEmpty
                        ?? anchor["aria-label"].replacingOccurrences(of: "Ver ", with: "")
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(title: title, url: page)
                }
            guard let match = results.bestMatch(for: context) else { continue }

            let links: [HosterLink]
            if let episode = context.request.episode {
                links = try await episodeLinks(show: match.url, episode: episode)
            } else {
                let page = try await text(match.url)
                guard let movieID = SpanishScraping.objectID("movie", in: page) else { continue }
                links = Self.parse(try await action(
                    Self.movieLinksAction, payload: ["movie_id": movieID], page: match.url
                ), relativeTo: baseURL)
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    private func episodeLinks(show: URL, episode: MediaEpisode) async throws -> [HosterLink] {
        let detail = try await text(show)
        guard let serieID = SpanishScraping.capture(#"\\?"serie_id\\?"\s*:\s*\\?"([a-f0-9]{24})"#, in: detail)
            ?? SpanishScraping.objectID("serie", in: detail) else { return [] }

        let payload: [String: Any] = [
            "serie_id": serieID,
            "season_number": episode.seasonNumber,
            "page": 1,
            "limit": 100,
            "sort": "NUMBER_ASC",
            "brandHost": "doramasflix.in",
        ]
        let response = try await action(Self.episodesAction, payload: payload, page: show)
        let items = (response as? [[String: Any]])
            ?? ((response as? [String: Any])?["items"] as? [[String: Any]]) ?? []
        guard let slug = items.first(where: {
            ($0["episode_number"] as? Int) == episode.number
        })?["slug"] as? String else { return [] }

        let episodePage = try url("episodios/\(slug)")
        guard let episodeID = SpanishScraping.objectID("episode", in: try await text(episodePage)) else { return [] }
        return Self.parse(try await action(
            Self.episodeLinksAction, payload: ["episode_id": episodeID], page: episodePage
        ), relativeTo: baseURL)
    }

    private func action(_ identifier: String, payload: [String: Any], page: URL) async throws -> Any? {
        let body = try JSONSerialization.data(withJSONObject: [payload])
        let raw = try await text(page, referer: page, headers: [
            "Next-Action": identifier,
            "Accept": "text/x-component",
            "Content-Type": "text/plain;charset=UTF-8",
        ], body: body)
        guard let line = raw.split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { $0.hasPrefix("1:") }) else { return nil }
        return try? JSONSerialization.jsonObject(
            with: Data(line.dropFirst(2).utf8), options: [.fragmentsAllowed]
        )
    }

    private static func parse(_ response: Any?, relativeTo base: URL) -> [HosterLink] {
        guard let items = response as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let raw = item["link"] as? String,
                  let target = ProviderNetwork.absolute(
                      SpanishScraping.unwrapEmbedShortener(raw), relativeTo: base
                  ) else { return nil }
            let language = (item["lang"] as? String)?.uppercased() ?? ""
            let name = [target.host ?? "Server", language].filter { !$0.isEmpty }.joined(separator: " ")
            return HosterLink(name: name, url: target, referer: base, audioLanguage: "es")
        }
    }
}

// MARK: - AnimeOnline Ninja

/// DooPlay theme that hands out embeds through its `dooplayer` REST route.
struct AnimeOnlineNinjaPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "animeonlineninja" }
    var displayName: String { "AnimeOnline Ninja" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://ver.animeonline.ninja/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.hasClass("result-item") }
                .compactMap { item -> ScrapedResult? in
                    guard let anchor = item.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                          let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let title = item.first { $0.hasClass("title") }?.text ?? anchor.text
                    return ScrapedResult(
                        title: title,
                        year: TitleMatch.year(item.first { $0.hasClass("year") }?.text),
                        kind: anchor["href"].contains("/pelicula/") ? .movie : .series,
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
            var links: [HosterLink] = []
            for option in document.all({ !$0["data-nume"].isEmpty && !$0["data-post"].isEmpty }) {
                let type = option["data-type"].nonEmpty
                    ?? (context.request.episode == nil ? "movie" : "tv")
                let endpoint = try url(
                    "wp-json/dooplayer/v1/post/\(option["data-post"])",
                    query: ["type": type, "source": option["data-nume"]]
                )
                guard let payload = try? await jsonObject(endpoint, referer: page),
                      let raw = payload["embed_url"] as? String,
                      let embed = ProviderNetwork.absolute(raw, relativeTo: page) else { continue }

                if embed.host == baseURL.host {
                    let nested = (try? await text(embed, referer: page)) ?? ""
                    links += SpanishScraping.playerLinks(in: nested, page: embed)
                        .map { HosterLink(name: $0.name, url: $0.url, referer: embed, audioLanguage: "es") }
                } else {
                    let label = option.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    links.append(HosterLink(
                        name: label.isEmpty ? (embed.host ?? "Server") : label,
                        url: embed,
                        referer: page,
                        audioLanguage: "es"
                    ))
                }
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - SoloLatino

/// Laravel site: server buttons hand back an embed url from `/api/player-url`,
/// and the embed page carries the hosters in a `dataLink` array.
struct SoloLatinoPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "sololatino" }
    var displayName: String { "SoloLatino" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://sololatino.net/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("buscar", query: ["q": query]))
            let results = search.all { $0.hasClass("card") }.compactMap { card -> ScrapedResult? in
                let anchor = card.first { $0.tag == "a" && !$0["href"].isEmpty }
                    ?? card.ancestor { $0.tag == "a" && !$0["href"].isEmpty }
                guard let anchor, let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL),
                      let title = (card.first { $0.hasClass("card__title") }?.text).flatMap({ $0.nonEmpty })
                else { return nil }
                return ScrapedResult(
                    title: title,
                    year: TitleMatch.year(card.first { $0.hasClass("card__year") }?.text),
                    kind: anchor["href"].contains("/pelicula") ? .movie : .series,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                let detail = try await html(match.url)
                let panel = detail.first { $0["data-season-panel"] == String(episode.seasonNumber) }
                guard let row = (panel ?? detail).first({ node in
                    guard node.tag == "a", node.hasClass("ep-item") else { return false }
                    let text = node.first { $0.hasClass("ep-num") }?.text ?? ""
                    return Int(text.filter(\.isNumber)) == episode.number
                }), let resolved = ProviderNetwork.absolute(row["href"], relativeTo: match.url) else { continue }
                page = resolved
            }

            var links: [HosterLink] = []
            for embed in try await embedURLs(on: page) {
                let raw = (try? await text(embed, referer: page)) ?? ""
                let parsed = SpanishScraping.dataLinks(in: raw, page: embed)
                    + SpanishScraping.playerLinks(in: raw, page: embed)
                if parsed.isEmpty {
                    links.append(HosterLink(
                        name: embed.host ?? "Server", url: embed, referer: page, audioLanguage: "es"
                    ))
                } else {
                    links += parsed.map {
                        HosterLink(name: $0.name, url: $0.url, referer: embed, audioLanguage: $0.language ?? "es")
                    }
                }
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    private func embedURLs(on page: URL) async throws -> [URL] {
        let document = try await html(page)
        var embeds: [URL] = []
        let buttons = document.all {
            !$0["data-server-url"].isEmpty || !$0["data-player-token"].isEmpty
                || (!$0["data-player-id"].isEmpty && !$0["data-player-model"].isEmpty)
        }
        for button in buttons {
            if let direct = ProviderNetwork.absolute(
                button["data-server-url"].nonEmpty ?? button["data-url"], relativeTo: page
            ) {
                embeds.append(direct)
                continue
            }
            let payload: [String: Any]?
            if let token = button["data-player-token"].nonEmpty {
                payload = try? await jsonObject(
                    url("api/player-url"),
                    referer: page,
                    headers: ["X-Requested-With": "XMLHttpRequest"],
                    body: try JSONSerialization.data(withJSONObject: ["t": token])
                )
            } else {
                payload = try? await jsonObject(
                    url("api/player-url/\(button["data-player-model"])/\(button["data-player-id"])"),
                    referer: page,
                    headers: ["X-Requested-With": "XMLHttpRequest"]
                )
            }
            guard let raw = (payload?["url"] ?? payload?["embed"] ?? payload?["link"]) as? String,
                  let resolved = ProviderNetwork.absolute(raw, relativeTo: page) else { continue }
            embeds.append(resolved)
        }
        return embeds
    }
}

// MARK: - Cine24h

/// WordPress theme whose player list holds base64 urls to in-house embed pages.
struct Cine24hPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "cine24h" }
    var displayName: String { "Cine24h" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://cine24h.online/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query, "paged": "1"]))
            let results = search.all { $0.tag == "article" }.compactMap { article -> ScrapedResult? in
                guard let anchor = article.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let href = anchor["href"]
                guard href.contains("/peliculas/") || href.contains("/series/") else { return nil }
                let title = article.first { $0.hasClass("Title") }?.text
                    ?? article.first { $0.tag == "h2" || $0.tag == "h3" }?.text
                    ?? ""
                guard !title.isEmpty else { return nil }
                return ScrapedResult(
                    title: title,
                    year: TitleMatch.year(article.first { $0.hasClass("Year") }?.text),
                    kind: href.contains("/series/") ? .series : .movie,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                let detail = try await html(match.url)
                let boxes = detail.all { $0.hasClass("AABox") }
                let box = boxes.first { box in
                    let title = box.first { $0.hasClass("Title") }?.text ?? ""
                    return AnimeHTML.captures(#"(\d+)\s*$"#, in: title).first.flatMap { Int($0[1]) }
                        == episode.seasonNumber
                } ?? boxes.first
                guard let box, let row = box.first({ node in
                    guard node.tag == "tr" || node.tag == "li" else { return false }
                    let number = node.first { $0.hasClass("Num") }?.text ?? ""
                    return Int(number.filter(\.isNumber)) == episode.number
                }), let anchor = row.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                    let resolved = ProviderNetwork.absolute(anchor["href"], relativeTo: match.url) else { continue }
                page = resolved
            }

            let document = try await html(page)
            let links = document.all { $0.tag == "li" && !$0["data-src"].isEmpty }
                .compactMap { option -> HosterLink? in
                    guard let decoded = SpanishScraping.base64Text(option["data-src"]),
                          let target = ProviderNetwork.absolute(decoded, relativeTo: page) else { return nil }
                    let label = option.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return HosterLink(
                        name: label.isEmpty ? (target.host ?? "Server") : label,
                        url: target,
                        referer: page,
                        audioLanguage: "es"
                    )
                }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - Pelisplusto

/// The player page assigns every mirror to a `video[n]` javascript slot.
struct PelisplustoPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "pelisplusto" }
    var displayName: String { "PelisPlus" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://pelisplushd.bz/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("search", query: ["s": query]))
            let results = search.all { $0.tag == "a" && !$0["href"].isEmpty }
                .compactMap { anchor -> ScrapedResult? in
                    let href = anchor["href"]
                    guard !href.contains("/temporada/"),
                          href.contains("/pelicula/") || href.contains("/serie/") || href.contains("/anime/"),
                          let page = ProviderNetwork.absolute(href, relativeTo: baseURL) else { return nil }
                    let title = anchor["data-title"].nonEmpty
                        ?? anchor.first { $0.tag == "img" }?["alt"].nonEmpty
                        ?? anchor.first { $0.tag == "h2" }?.text
                        ?? ""
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(
                        title: title,
                        kind: href.contains("/pelicula/") ? .movie : .series,
                        url: page
                    )
                }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                guard let resolved = URL(
                    string: "\(match.url.absoluteString.trimmedSlash)/temporada/\(episode.seasonNumber)/capitulo/\(episode.number)"
                ) else { continue }
                page = resolved
            }

            let raw = try await text(page)
            let document = AnimeHTML.parse(raw)
            let labels = document.all { !$0["data-id"].isEmpty && $0.tag == "li" }
                .reduce(into: [String: String]()) { result, item in
                    result[item["data-id"]] = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            var links = AnimeHTML.captures(#"video\[(\d+)\]\s*=\s*['"]([^'"]+)['"]"#, in: raw)
                .compactMap { capture -> HosterLink? in
                    guard let target = ProviderNetwork.absolute(capture[2], relativeTo: page) else { return nil }
                    let label = labels[capture[1]]?.nonEmpty ?? target.host ?? "Server \(capture[1])"
                    return HosterLink(name: label, url: target, referer: page, audioLanguage: "es")
                }
            if links.isEmpty { links = embedLinks(in: document, page: page, named: "PelisPlus") }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - PelisflixHD

/// Showcase theme: every mirror sits in a base64 `data-server` attribute.
struct PelisflixHdPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "pelisflixhd" }
    var displayName: String { "PelisflixHD" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://pelisflixhd1.top/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("busqueda/\(ProviderNetwork.encoded(query))"))
            let results = search.all { $0.tag == "a" && !$0["href"].isEmpty }
                .compactMap { anchor -> ScrapedResult? in
                    let href = anchor["href"]
                    guard href.contains("/pelicula/") || href.contains("/serie/"),
                          let page = ProviderNetwork.absolute(href, relativeTo: baseURL) else { return nil }
                    let title = anchor.first { $0.hasClass("item-detail") }?.text.nonEmpty
                        ?? anchor.first { $0.tag == "img" }?["alt"]
                            .replacingOccurrences(of: "Poster ", with: "").nonEmpty
                        ?? ""
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(
                        title: title,
                        year: TitleMatch.year(anchor.first { $0.hasClass("card-hover-year") }?.text),
                        kind: href.contains("/pelicula/") ? .movie : .series,
                        url: page
                    )
                }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                guard let resolved = try await episodeURL(show: match.url, episode: episode) else { continue }
                page = resolved
            }

            let document = try await html(page)
            let links = document.all { !$0["data-server"].isEmpty }
                .compactMap { option -> HosterLink? in
                    guard let decoded = SpanishScraping.base64Text(option["data-server"]),
                          let target = ProviderNetwork.absolute(decoded, relativeTo: page) else { return nil }
                    let label = option.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return HosterLink(
                        name: label.isEmpty ? (target.host ?? "Server") : label,
                        url: target,
                        referer: page,
                        audioLanguage: "es"
                    )
                }
            if !links.isEmpty { return links }
        }
        return []
    }

    private func episodeURL(show: URL, episode: MediaEpisode) async throws -> URL? {
        let detail = try await html(show)
        let seasons = detail.all { $0.tag == "a" && $0["href"].contains("/temporada/") }
        let season = seasons.first { anchor in
            AnimeHTML.captures(#"-(\d+)/?$"#, in: anchor["href"]).first.flatMap { Int($0[1]) } == episode.seasonNumber
        } ?? seasons.first
        guard let season, let seasonPage = ProviderNetwork.absolute(season["href"], relativeTo: show) else { return nil }

        let document = try await html(seasonPage)
        for anchor in document.all({ $0.tag == "a" && $0["href"].contains("/episodio/") }) {
            let codes = anchor.all { $0.tag == "span" }.map(\.text)
            let code = codes.count > 1 ? codes[1] : (codes.first ?? "")
            guard let capture = AnimeHTML.captures(#"x(\d+)"#, in: code).first,
                  Int(capture[1]) == episode.number else { continue }
            return ProviderNetwork.absolute(anchor["href"], relativeTo: seasonPage)
        }
        return nil
    }
}

// MARK: - PoseidonHD2

/// Next.js site: the page props carry every mirror grouped by audio language.
struct PoseidonHD2PlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "poseidonhd2" }
    var displayName: String { "PoseidonHD" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://www.poseidonhd2.co/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("buscar", query: ["q": query]))
            let results = search.all { $0.hasClass("TPostMv") || $0.hasClass("TPost") }
                .compactMap { item -> ScrapedResult? in
                    guard let anchor = item.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                          let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                    let href = anchor["href"]
                    guard href.contains("/pelicula/") || href.contains("/serie/") else { return nil }
                    let title = item.first { $0.hasClass("Title") }?.text
                        ?? item.first { $0.tag == "h3" }?.text ?? ""
                    guard !title.isEmpty else { return nil }
                    return ScrapedResult(
                        title: title,
                        year: TitleMatch.year(item.first { $0.hasClass("Year") }?.text),
                        kind: href.contains("/serie/") ? .series : .movie,
                        url: page
                    )
                }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                guard let resolved = URL(
                    string: "\(match.url.absoluteString.trimmedSlash)/temporada/\(episode.seasonNumber)/episodio/\(episode.number)"
                ) else { continue }
                page = resolved
            }

            let raw = try await text(page)
            guard let props = SpanishScraping.nextPageProps(in: raw) else { continue }
            let holder = (props["thisMovie"] as? [String: Any])
                ?? (props["episode"] as? [String: Any])
                ?? (props["thisEpisode"] as? [String: Any])
            guard let videos = holder?["videos"] as? [String: Any] else { continue }

            var links: [HosterLink] = []
            for (key, tag) in [("latino", "LAT"), ("spanish", "CAST"), ("english", "SUB")] {
                for entry in (videos[key] as? [[String: Any]]) ?? [] {
                    guard let raw = entry["result"] as? String,
                          let target = ProviderNetwork.absolute(raw, relativeTo: page) else { continue }
                    let server = (entry["cyberlocker"] as? String)?.nonEmpty ?? target.host ?? "Server"
                    links.append(HosterLink(
                        name: "\(server) [\(tag)]",
                        url: target,
                        referer: page,
                        audioLanguage: key == "english" ? "en" : "es"
                    ))
                }
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - CineHax

/// TMDB-keyed watch pages that delegate playback to an unlimplay embed holding
/// a `EMBEDS` map of language to hoster.
struct CineHaxPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "cinehax" }
    var displayName: String { "CineHax" }
    var audioLanguage: String { "es" }
    var baseURL: URL { URL(string: "https://cinehax.com/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard let tmdbID = context.request.media.tmdbID else { return [] }
        var query = ["id": String(tmdbID), "type": context.request.episode == nil ? "movie" : "tv"]
        if let episode = context.request.episode {
            query["season"] = String(episode.seasonNumber)
            query["episode"] = String(episode.number)
        }
        let watch = try url("watch/", query: query)
        let raw = try await text(watch)

        var links: [HosterLink] = []
        var seen: Set<String> = []
        for capture in AnimeHTML.captures(#"data-url="(https?://[^"]*unlimplay[^"]*)""#, in: raw) {
            let value = HTMLPayloadParser.decodeEntities(capture[1])
            guard seen.insert(value).inserted,
                  let embed = ProviderNetwork.absolute(value, relativeTo: watch) else { continue }
            let page = (try? await text(embed, referer: watch)) ?? ""
            guard let payload = AnimeHTML.captures(#"const EMBEDS\s*=\s*(\{.*?\});"#, in: page).first,
                  let embeds = try? JSONSerialization.jsonObject(with: Data(payload[1].utf8)) as? [String: Any]
            else { continue }

            for (language, servers) in embeds {
                guard let servers = servers as? [String: Any] else { continue }
                for (server, value) in servers {
                    guard let raw = value as? String,
                          let target = ProviderNetwork.absolute(raw, relativeTo: embed) else { continue }
                    links.append(HosterLink(
                        name: "\(server.capitalizedFirst) · \(language.capitalizedFirst)",
                        url: target,
                        referer: embed,
                        audioLanguage: language.lowercased() == "subtitulado" ? "en" : "es",
                        isDirect: target.host?.contains("remux.") == true
                    ))
                }
            }
        }
        return links
    }
}

// MARK: - Shared helpers

/// Decoding shared by the Spanish sites: base64 payloads, Next.js props and the
/// obfuscated link lists their embed pages ship.
enum SpanishScraping {
    static func base64Text(_ value: String) -> String? {
        var padded = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !padded.isEmpty else { return nil }
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded.nonEmpty
    }

    static func capture(_ pattern: String, in text: String) -> String? {
        AnimeHTML.captures(pattern, in: text).first.map { $0[1] }?.nonEmpty
    }

    /// Mongo ids inside Next.js flight payloads, where quotes are often escaped.
    static func objectID(_ key: String, in text: String) -> String? {
        capture(#"\\?"\#(key)\\?"\s*:\s*\\?\{\s*\\?"_id\\?"\s*:\s*\\?"([a-f0-9]{24})"#, in: text)
    }

    static func nextPageProps(in text: String) -> [String: Any]? {
        guard let payload = capture(#"<script[^>]+id="__NEXT_DATA__"[^>]*>(.*?)</script>"#, in: text),
              let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
        else { return nil }
        return (json["props"] as? [String: Any])?["pageProps"] as? [String: Any]
    }

    /// `doramasflix` hides the hoster behind a shortener that base64-nests it twice.
    static func unwrapEmbedShortener(_ link: String) -> String {
        guard link.contains("embedshortener"), let token = link.components(separatedBy: "/e/").last else { return link }
        let payload = token.components(separatedBy: CharacterSet(charactersIn: "?#"))[0]
        let parts = payload.split(separator: ".")
        guard parts.count > 1, let claims = base64Text(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: Data(claims.utf8)) as? [String: Any],
              let inner = json["link"] as? String else { return link }
        return base64Text(inner) ?? inner
    }

    struct EmbedLink: Sendable {
        let name: String
        let url: URL
        var language: String?
    }

    /// `go_to_player('url')` option lists used by the DooPlay style embed pages.
    static func playerLinks(in text: String, page: URL) -> [EmbedLink] {
        var seen: Set<String> = []
        return AnimeHTML.captures(#"go_to_player(?:Vast)?\(\s*['"]([^'"]+)['"]"#, in: text)
            .compactMap { capture in
                guard let url = ProviderNetwork.absolute(capture[1], relativeTo: page),
                      !url.absoluteString.hasSuffix(".xml"),
                      seen.insert(url.absoluteString).inserted else { return nil }
                return EmbedLink(name: url.host ?? "Server", url: url)
            }
    }

    /// `dataLink` arrays hold one entry per audio language, each with a list of
    /// hosters whose url is wrapped in a JWT-shaped payload.
    static func dataLinks(in text: String, page: URL) -> [EmbedLink] {
        guard let payload = capture(#"dataLink\s*=\s*(\[[\s\S]*?\])\s*;"#, in: text),
              let items = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]]
        else { return [] }

        var links: [EmbedLink] = []
        for item in items {
            let tag = (item["video_language"] as? String)?.uppercased() ?? ""
            for embed in (item["sortedEmbeds"] as? [[String: Any]]) ?? [] {
                let server = (embed["servername"] as? String) ?? ""
                guard !server.caseInsensitiveEquals("download"), let raw = embed["link"] as? String else { continue }
                let claims = raw.split(separator: ".")
                let decoded: String?
                if claims.count == 3 {
                    decoded = base64Text(String(claims[1])).flatMap { payload in
                        (try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])?
                            .flatMap { $0["link"] as? String }
                    }
                } else {
                    decoded = base64Text(raw)
                }
                guard let decoded, let url = ProviderNetwork.absolute(decoded, relativeTo: page) else { continue }
                links.append(EmbedLink(
                    name: [server, tag].filter { !$0.isEmpty }.joined(separator: " "),
                    url: url,
                    language: tag == "JAP" ? "ja" : (tag == "SUB" ? "en" : "es")
                ))
            }
        }
        return links
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var trimmedSlash: String { hasSuffix("/") ? String(dropLast()) : self }
    var capitalizedFirst: String { isEmpty ? self : prefix(1).uppercased() + dropFirst() }
    func caseInsensitiveEquals(_ other: String) -> Bool { caseInsensitiveCompare(other) == .orderedSame }
}

// MARK: - DooPlay helpers

/// Season/episode navigation shared by the DooPlay-themed Spanish sites.
enum DooPlay {
    static func episodeURL(
        show: URL,
        episode: MediaEpisode,
        provider: some ScrapedPlaybackProvider
    ) async throws -> URL? {
        let document = try await provider.html(show)
        let rows = document.all { $0.tag == "li" && $0.first { node in node.hasClass("numerando") } != nil }
        for row in rows {
            let numbering = row.first { $0.hasClass("numerando") }?.text ?? ""
            guard let parts = AnimeHTML.captures(#"(\d+)\s*[-x]\s*(\d+)"#, in: numbering).first,
                  Int(parts[1]) == episode.seasonNumber, Int(parts[2]) == episode.number,
                  let href = row.first({ $0.tag == "a" && !$0["href"].isEmpty })?["href"] else { continue }
            return ProviderNetwork.absolute(href, relativeTo: show)
        }
        return nil
    }
}
