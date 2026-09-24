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
