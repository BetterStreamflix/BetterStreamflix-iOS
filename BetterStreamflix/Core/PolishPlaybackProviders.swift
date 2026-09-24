import Foundation

/// Polish-language BetterStreamflix providers ported from the Android catalogue.

// MARK: - FilmyOnline

/// JSON site: search, title, season and watch all come from `/api/v1`, which
/// answers with the hoster list for a video id.
struct FilmyOnlineCcPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "filmyonlinecc" }
    var displayName: String { "FilmyOnline" }
    var audioLanguage: String { "pl" }
    var baseURL: URL { URL(string: "https://filmyonline.cc/")! }

    private var apiHeaders: [String: String] {
        [
            "X-Requested-With": "XMLHttpRequest",
            "Accept-Language": "pl-PL,pl;q=0.9,en-US;q=0.8,en;q=0.7",
            "Origin": "https://filmyonline.cc",
        ]
    }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let encoded = ProviderNetwork.encoded(query)
            let search = try await jsonObject(
                url("api/v1/search/\(encoded)", query: ["loader": "searchPage"]),
                referer: url("search/\(encoded)"),
                headers: apiHeaders
            )
            let titles = (search["results"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
                .filter { $0["model_type"] as? String == "title" }
            guard let match = Self.bestTitle(in: titles, context: context),
                  let titleID = Self.number(match["id"]) else { continue }

            guard let watchID = try await watchID(for: context, title: match, titleID: titleID) else { continue }
            let links = try await hosters(watchID: watchID)
            if !links.isEmpty { return links }
        }
        return []
    }

    private func watchID(
        for context: PlaybackLookupContext,
        title: [String: Any],
        titleID: Int
    ) async throws -> Int? {
        guard let episode = context.request.episode else {
            if let primary = Self.primaryVideoID(title) { return primary }
            let page = try await jsonObject(
                url("api/v1/titles/\(titleID)", query: ["loader": "titlePage"]),
                headers: apiHeaders
            )
            return (page["title"] as? [String: Any]).flatMap(Self.primaryVideoID)
        }

        let season = try await jsonObject(
            url("api/v1/titles/\(titleID)/seasons/\(episode.seasonNumber)", query: ["loader": "seasonPage"]),
            headers: apiHeaders
        )
        let entries = ((season["episodes"] as? [String: Any])?["data"] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
        let wanted = entries.first { Self.number($0["episode_number"]) == episode.number }
        return wanted.flatMap(Self.primaryVideoID)
    }

    private func hosters(watchID: Int) async throws -> [HosterLink] {
        let watch = try await jsonObject(url("api/v1/watch/\(watchID)"), headers: apiHeaders)
        var videos = (watch["videos"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        if videos.isEmpty, let single = watch["video"] as? [String: Any] { videos = [single] }

        return videos.compactMap { video -> HosterLink? in
            guard let raw = video["src"] as? String,
                  let source = ProviderNetwork.absolute(raw, relativeTo: baseURL) else { return nil }
            let quality = (video["quality"] as? String)?.uppercased() ?? ""
            let language = video["language"] as? String
            let name = [quality.isEmpty ? (source.host ?? "Server") : quality, language.map { "[\($0)]" }]
                .compactMap { $0 }
                .joined(separator: " ")
            return HosterLink(name: name, url: source, referer: baseURL, audioLanguage: language ?? "pl")
        }
    }

    private static func bestTitle(in titles: [[String: Any]], context: PlaybackLookupContext) -> [String: Any]? {
        let wantsSeries = context.request.media.kind == .series
        let typed = titles.filter { ($0["is_series"] as? Bool ?? false) == wantsSeries }
        let results = typed.compactMap { title -> ScrapedResult? in
            guard let name = title["name"] as? String, let id = number(title["id"]),
                  let url = URL(string: "https://filmyonline.cc/titles/\(id)") else { return nil }
            let released = (title["release_date"] as? String) ?? (title["year"].map { String(describing: $0) })
            return ScrapedResult(
                title: name,
                year: TitleMatch.year(released),
                kind: wantsSeries ? .series : .movie,
                url: url
            )
        }
        guard let best = results.bestMatch(for: context) else { return nil }
        return typed.first { number($0["id"]).map { "https://filmyonline.cc/titles/\($0)" } == best.url.absoluteString }
    }

    /// The full-length video of a title, preferring the one the site marks primary.
    private static func primaryVideoID(_ container: [String: Any]) -> Int? {
        if let primary = container["primary_video"] as? [String: Any], let id = number(primary["id"]), id > 0 {
            return id
        }
        let videos = (container["videos"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let full = videos.first { video in
            ["category", "type"].contains { key in
                (video[key] as? String)?.caseInsensitiveCompare("full") == .orderedSame
            }
        }
        return (full.flatMap { number($0["id"]) } ?? videos.first.flatMap { number($0["id"]) }).flatMap { $0 > 0 ? $0 : nil }
    }

    private static func number(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

// MARK: - Zaluknij

/// DooPlay mirror with two generations of markup: the modern player options
/// resolved over `doo_player_ajax`, and a legacy table of base64 iframes.
struct ZaluknijPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "zaluknij" }
    var displayName: String { "Zaluknij" }
    var audioLanguage: String { "pl" }
    var baseURL: URL { URL(string: "https://zaluknij.pl/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.hasClass("result-item") }.compactMap { item -> ScrapedResult? in
                guard let anchor = item.first({ $0.tag == "a" && !$0["href"].isEmpty }),
                      let page = ProviderNetwork.absolute(anchor["href"], relativeTo: baseURL) else { return nil }
                let href = anchor["href"]
                let isMovie = href.contains("/filmy-online/") || href.contains("/film/")
                let isSeries = href.contains("/seriale-online/") || href.contains("/serial-online/")
                guard isMovie || isSeries else { return nil }
                let title = item.first { $0.hasClass("title") }?.text ?? anchor.text
                return ScrapedResult(
                    title: title,
                    year: TitleMatch.year(item.first { $0.hasClass("year") }?.text),
                    kind: isMovie ? .movie : .series,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }

            var page = match.url
            if let episode = context.request.episode {
                guard let resolved = try await episodeURL(show: match.url, episode: episode) else { continue }
                page = resolved
            }

            let links = try await servers(on: page)
            if !links.isEmpty { return links }
        }
        return []
    }

    private func episodeURL(show: URL, episode: MediaEpisode) async throws -> URL? {
        if let modern = try await DooPlay.episodeURL(show: show, episode: episode, provider: self) { return modern }
        // Older mirrors list every season as a `Sezon N` block of `/odcinek-N/` links.
        let document = try await html(show)
        guard let block = document.first({ node in
            guard node.tag == "li" || node.hasClass("se-c") else { return false }
            guard let label = node.first({ $0.tag == "span" })?.text else { return false }
            return Self.seasonNumber(in: label) == episode.seasonNumber
        }) else { return nil }
        let anchor = block.first { node in
            node.tag == "a" && node["href"].contains("/odcinek-")
                && Self.episodeNumber(in: node.text) == episode.number
        }
        return anchor.flatMap { ProviderNetwork.absolute($0["href"], relativeTo: show) }
    }

    private func servers(on page: URL) async throws -> [HosterLink] {
        let document = try await html(page)
        var links: [HosterLink] = []

        for option in document.all({ !$0["data-post"].isEmpty && !$0["data-nume"].isEmpty }) {
            let nume = option["data-nume"]
            guard nume.caseInsensitiveCompare("trailer") != .orderedSame else { continue }
            let type = option["data-type"].isEmpty ? "movie" : option["data-type"]
            let ajax = try url("wp-admin/admin-ajax.php", query: [
                "action": "doo_player_ajax",
                "post": option["data-post"],
                "nume": nume,
                "type": type,
            ])
            guard let payload = try? await text(ajax, referer: page, headers: ["X-Requested-With": "XMLHttpRequest"]),
                  let embed = Self.embed(in: payload, relativeTo: page) else { continue }
            let label = option.first { $0.hasClass("title") }?.text ?? ""
            links.append(HosterLink(
                name: label.isEmpty ? (embed.host ?? "Server") : label,
                url: embed,
                referer: page,
                audioLanguage: "pl"
            ))
        }

        for source in document.all({ $0.tag == "source" && !$0["src"].isEmpty }) {
            let raw = source["src"]
            // The theme plays a bumper before the feature; it is not the title.
            guard !raw.lowercased().contains("intro"),
                  let file = ProviderNetwork.absolute(raw, relativeTo: page) else { continue }
            let label = source["label"].isEmpty ? "Direct" : source["label"]
            links.append(HosterLink(
                name: label,
                url: file,
                referer: page,
                audioLanguage: "pl",
                isDirect: HosterResolver.isDirect(file)
            ))
        }

        if let table = document.first({ $0["id"] == "link-list" }) {
            for row in table.all({ $0.tag == "tr" }) {
                guard let anchor = row.first({ $0.tag == "a" && !$0["href"].isEmpty }) else { continue }
                let decoded = Self.legacyIframe(anchor["data-iframe"]) ?? anchor["href"]
                guard let embed = ProviderNetwork.absolute(decoded, relativeTo: page) else { continue }
                let host = anchor.first { $0.tag == "img" }?["alt"] ?? ""
                links.append(HosterLink(
                    name: host.isEmpty ? (embed.host ?? "Server") : host,
                    url: embed,
                    referer: page,
                    audioLanguage: "pl"
                ))
            }
        }

        return links
    }

    /// The ajax endpoint answers with either a JSON `embed_url` or bare iframe markup.
    private static func embed(in payload: String, relativeTo page: URL) -> URL? {
        if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
           let raw = ["embed_url", "embed", "url"].compactMap({ json[$0] as? String }).first(where: { !$0.isEmpty }) {
            return ProviderNetwork.absolute(raw, relativeTo: page)
        }
        guard let raw = HosterResolver.findIframe(in: payload)
            ?? SpanishScraping.capture(#"(?:embed_url|src)\s*[:=]\s*["']([^"']+)["']"#, in: payload) else { return nil }
        return ProviderNetwork.absolute(raw, relativeTo: page)
    }

    private static func legacyIframe(_ encoded: String) -> String? {
        guard let decoded = SpanishScraping.base64Text(encoded) else { return nil }
        if let json = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any],
           let src = json["src"] as? String, !src.isEmpty { return src }
        return decoded.hasPrefix("http") ? decoded : nil
    }

    private static func seasonNumber(in label: String) -> Int? {
        AnimeHTML.captures(#"\b(?:sezon|s)\s*0*(\d+)\b"#, in: label).first.flatMap { Int($0[1]) }
    }

    private static func episodeNumber(in label: String) -> Int? {
        AnimeHTML.captures(#"\b(?:odcinek|e)\s*0*(\d+)\b"#, in: label).first.flatMap { Int($0[1]) }
    }
}
