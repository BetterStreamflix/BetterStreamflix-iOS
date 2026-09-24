import Foundation
import CryptoKit

/// English-language BetterStreamflix providers ported from the Android catalogue.

// MARK: - SFlix

/// Rabbitstream-style catalogue: search page → ajax server list → ajax source link.
struct SflixPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "sflix" }
    var displayName: String { "SFlix" }
    var baseURL: URL { URL(string: "https://sflix.to/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let slug = query.replacingOccurrences(of: " ", with: "-")
            let search = try await html(url("search/\(ProviderNetwork.encoded(slug))"))
            let results = search.all { $0.hasClass("flw-item") }.compactMap { item -> ScrapedResult? in
                guard let href = item.first({ $0.tag == "a" && !$0["href"].isEmpty })?["href"],
                      let page = ProviderNetwork.absolute(href, relativeTo: baseURL) else { return nil }
                let title = item.first { $0.hasClass("film-name") }?.text ?? ""
                let details = item.all { $0.tag == "span" }.map(\.text)
                let year = details.compactMap { Int($0) }.first { (1900...2100).contains($0) }
                return ScrapedResult(
                    title: title,
                    year: year,
                    kind: href.contains("/movie/") ? .movie : .series,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context),
                  let numericID = match.url.lastPathComponent.components(separatedBy: "-").last else { continue }

            let serverID: String
            switch context.request.media.kind {
            case .movie:
                serverID = numericID
            case .series:
                guard let episode = context.request.episode else { return [] }
                let seasons = try await html(url("ajax/season/list/\(numericID)"))
                    .all { $0.tag == "a" && !$0["data-id"].isEmpty }
                guard episode.seasonNumber >= 1, seasons.count >= episode.seasonNumber else { continue }
                let seasonID = seasons[episode.seasonNumber - 1]["data-id"]
                let episodes = try await html(url("ajax/season/episodes/\(seasonID)"))
                    .all { $0.hasClass("eps-item") && !$0["data-id"].isEmpty }
                guard let match = episodes.first(where: { node in
                    let label = node.first { $0.hasClass("episode-number") }?.text ?? ""
                    return AnimeHTML.captures(#"Episode\s+(\d+)"#, in: label).first.flatMap { Int($0[1]) } == episode.number
                }) else { continue }
                serverID = match["data-id"]
            }

            let servers = try await html(
                url(context.request.media.kind == .movie
                    ? "ajax/episode/list/\(serverID)"
                    : "ajax/episode/servers/\(serverID)")
            )
            let links = servers.all { $0.tag == "a" && !$0["data-id"].isEmpty }.compactMap { node -> HosterLink? in
                let name = node.first { $0.tag == "span" }?.text ?? node.text
                guard let sourceURL = try? url("ajax/episode/sources/\(node["data-id"])") else { return nil }
                let client = client
                let base = baseURL
                return HosterLink(
                    name: name.isEmpty ? "SFlix" : name,
                    url: sourceURL,
                    referer: base,
                    resolveOverride: {
                        let response = try await ProviderNetwork.data(
                            client: client, url: sourceURL, referer: base, acceptsJSON: true
                        )
                        guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                              let link = payload["link"] as? String,
                              let embed = ProviderNetwork.absolute(link, relativeTo: base) else { throw AppError.noStream }
                        return try await HosterResolver(client: client).resolve(embed, referer: base)
                    }
                )
            }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - Ridomovies

/// JSON search API plus a detail page whose players live in `data-embed`.
struct RidomoviesPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "ridomovies" }
    var displayName: String { "Ridomovies" }
    var baseURL: URL { URL(string: "https://ridomovies.su/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let payload = try await jsonObject(url("api/search", query: [
                "q": query, "page": "1", "lang": "en", "limit": "20",
            ]))
            let rows = (payload["data"] as? [[String: Any]]) ?? []
            let results = rows.compactMap { row -> (ScrapedResult, String)? in
                guard let slug = row["slug"] as? String ?? row["slugEn"] as? String,
                      let title = row["title"] as? String else { return nil }
                let type = row["type"] as? String
                let kind: MediaKind? = type == "movie" ? .movie : type == "tv" ? .series : nil
                let year = TitleMatch.year(row["releaseDate"] as? String)
                guard let page = try? url(kind == .series ? "tv/\(slug)" : "movie/\(slug)") else { return nil }
                return (ScrapedResult(title: title, year: year, kind: kind, url: page), slug)
            }
            guard let match = results.map(\.0).bestMatch(for: context),
                  let slug = results.first(where: { $0.0.url == match.url })?.1 else { continue }

            let page: URL
            switch context.request.media.kind {
            case .movie:
                page = try url("movie/\(slug)")
            case .series:
                guard let episode = context.request.episode else { return [] }
                page = try url("tv/\(slug)/season-\(episode.seasonNumber)/episode-\(episode.number)")
            }
            let document = try await html(page)
            var links: [HosterLink] = []
            for node in document.all({ !$0["data-embed"].isEmpty || !$0["data-server-embed"].isEmpty }) {
                let raw = node["data-server-embed"].isEmpty ? node["data-embed"] : node["data-server-embed"]
                guard let embed = Self.embedURL(raw, relativeTo: page) else { continue }
                let label = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                links.append(HosterLink(
                    name: label.isEmpty ? "Ridomovies" : label,
                    url: embed,
                    referer: page
                ))
            }
            if links.isEmpty { links = embedLinks(in: document, page: page, named: "Ridomovies") }
            if !links.isEmpty { return links }
        }
        return []
    }

    /// `data-embed` holds either a bare URL or an escaped iframe snippet.
    private static func embedURL(_ raw: String, relativeTo base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http") || trimmed.hasPrefix("//") {
            return ProviderNetwork.absolute(trimmed, relativeTo: base)
        }
        guard let source = HosterResolver.findIframe(in: trimmed) else { return nil }
        return ProviderNetwork.absolute(source, relativeTo: base)
    }
}

// MARK: - AnyMovie

/// WordPress catalogue where each player option pairs an `aside.options` entry
/// with a numbered `div.player div.fgN` iframe.
struct AnyMoviePlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "anymovie" }
    var displayName: String { "AnyMovie" }
    var baseURL: URL { URL(string: "https://anymovie.cc/")! }

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        for query in TitleMatch.queries(for: context) {
            let search = try await html(url("", query: ["s": query]))
            let results = search.all { $0.tag == "article" }.compactMap { article -> ScrapedResult? in
                guard let href = article.all({ $0.tag == "a" && !$0["href"].isEmpty })
                    .first(where: { $0["href"].contains("/movies/") || $0["href"].contains("/series/") })?["href"],
                    let page = ProviderNetwork.absolute(href, relativeTo: baseURL) else { return nil }
                let title = article.first { $0.hasClass("entry-title") }?.text ?? ""
                let year = TitleMatch.year(article.first { $0.hasClass("year") }?.text)
                return ScrapedResult(
                    title: title,
                    year: year,
                    kind: href.contains("/series/") ? .series : .movie,
                    url: page
                )
            }
            guard let match = results.bestMatch(for: context) else { continue }

            let page: URL
            switch context.request.media.kind {
            case .movie:
                page = match.url
            case .series:
                guard let episode = context.request.episode else { return [] }
                let show = try await html(match.url)
                let seasons = show.all { $0.hasClass("seasons-bx") }
                guard episode.seasonNumber >= 1, seasons.count >= episode.seasonNumber else { continue }
                let rows = seasons[episode.seasonNumber - 1].all { $0.tag == "li" }
                guard let row = rows.first(where: { node in
                    let label = node.first { $0.hasClass("title") }?.text ?? ""
                    return AnimeHTML.captures(#"E(\d+)"#, in: label).first.flatMap { Int($0[1]) } == episode.number
                }), let href = row.first({ $0.tag == "a" && !$0["href"].isEmpty })?["href"],
                    let episodeURL = ProviderNetwork.absolute(href, relativeTo: baseURL) else { continue }
                page = episodeURL
            }

            let document = try await html(page)
            let options = document.all { $0.tag == "li" && !$0["data-id"].isEmpty }
            var links: [HosterLink] = []
            for (index, option) in options.enumerated() {
                guard let frame = document.first({ $0.hasClass("fg\(index + 1)") })?
                    .first({ $0.tag == "iframe" && !$0["src"].isEmpty }),
                    let embed = ProviderNetwork.absolute(frame["src"], relativeTo: page) else { continue }
                let name = option.first { $0.hasClass("option") }?.text ?? "Server \(index + 1)"
                if embed.absoluteString.contains("trembed") {
                    let client = client
                    links.append(HosterLink(name: name, url: embed, referer: page, resolveOverride: {
                        let wrapper = try await ProviderNetwork.data(client: client, url: embed, referer: page)
                        guard let body = String(data: wrapper.data, encoding: .utf8),
                              let inner = HosterResolver.findIframe(in: body),
                              let target = ProviderNetwork.absolute(inner, relativeTo: embed) else { throw AppError.noStream }
                        return try await HosterResolver(client: client).resolve(target, referer: embed)
                    }))
                } else {
                    links.append(HosterLink(name: name, url: embed, referer: page))
                }
            }
            if links.isEmpty { links = embedLinks(in: document, page: page, named: "AnyMovie") }
            if !links.isEmpty { return links }
        }
        return []
    }
}

// MARK: - MKissa

/// AllAnime-style GraphQL API. Episode sources sit behind the `aa-crypto`
/// handshake: derive the build mask, bootstrap a lane key, then sign the query.
struct MkissaPlaybackProvider: ScrapedPlaybackProvider {
    var id: String { "mkissa" }
    var displayName: String { "MKissa" }
    var baseURL: URL { URL(string: "https://api.mkissa.net/")! }
    var audioLanguage: String { "ja" }

    private static let searchHash = "a24c500a1b765c68ae1d8dd85174931f661c71369c89b92b88b75a725afc471c"
    private static let sourceHash = "d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec"
    private static let clockURL = "https://allanime.day"
    private static let siteHeaders = [
        "Origin": "https://mkissa.to",
        "Referer": "https://mkissa.to/",
        "x-build-id": MkissaCrypto.buildID,
    ]

    func hosterLinks(for context: PlaybackLookupContext) async throws -> [HosterLink] {
        guard context.isAnimation else { return [] }
        let wantsMovie = context.request.media.kind == .movie
        let episodeString = wantsMovie ? "1" : String(context.continuousEpisodeNumber ?? 1)

        for query in TitleMatch.queries(for: context) {
            var showID: String?
            for translation in ["sub", "dub"] where showID == nil {
                let variables: [String: Any] = [
                    "search": ["query": query],
                    "limit": 26,
                    "page": 1,
                    "translationType": translation,
                    "allowAdult": false,
                ]
                let response = try await api(variables: variables, hash: Self.searchHash, signed: false)
                let edges = ((response["data"] as? [String: Any])?["shows"] as? [String: Any])?["edges"] as? [[String: Any]]
                showID = (edges ?? []).first { show in
                    let type = (show["type"] as? String ?? "").lowercased()
                    guard wantsMovie == (type == "movie") else { return false }
                    let names = [show["name"], show["englishName"], show["nativeName"], show["nameOnlyString"]]
                        .compactMap { $0 as? String } + (show["altNames"] as? [String] ?? [])
                    let year = (show["airedStart"] as? [String: Any])?["year"] as? Int
                    return names.contains { TitleMatch.matches($0, year: year, context: context) }
                }?["_id"] as? String
            }
            guard let showID else { continue }

            var links: [HosterLink] = []
            for translation in ["sub", "dub"] {
                let variables: [String: Any] = [
                    "showId": showID,
                    "translationType": translation,
                    "episodeString": episodeString,
                ]
                guard let response = try? await api(variables: variables, hash: Self.sourceHash, signed: true) else { continue }
                let episode = (response["data"] as? [String: Any])?["episode"] as? [String: Any]
                let sources = episode?["sourceUrls"] as? [[String: Any]] ?? []
                for source in sources {
                    let raw = (source["sourceUrl"] as? String) ?? (source["url"] as? String) ?? ""
                    guard let resolved = Self.decodeSourceURL(raw) else { continue }
                    let name = (source["sourceName"] as? String ?? "MKissa") + " " + translation.uppercased()
                    if resolved.hasPrefix("/apivtwo/") {
                        let client = client
                        guard let clock = URL(string: Self.clockURL + resolved
                            .replacingOccurrences(of: "/apivtwo/clock?", with: "/apivtwo/clock.json?")) else { continue }
                        links.append(HosterLink(
                            name: name,
                            url: clock,
                            audioLanguage: translation == "dub" ? "en" : "ja",
                            resolveOverride: {
                                let response = try await ProviderNetwork.data(
                                    client: client, url: clock, referer: URL(string: Self.clockURL + "/player.html"),
                                    headers: ["Origin": Self.clockURL], acceptsJSON: true
                                )
                                guard let payload = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                                      let entries = payload["links"] as? [[String: Any]] else { throw AppError.noStream }
                                let file = entries.compactMap { entry in
                                    (entry["link"] ?? entry["url"] ?? entry["sourceUrl"] ?? entry["file"]) as? String
                                }.first
                                guard let file, let stream = ProviderNetwork.absolute(file, relativeTo: clock) else {
                                    throw AppError.noStream
                                }
                                if HosterResolver.isDirect(stream) {
                                    return PlaybackSource(
                                        url: stream,
                                        headers: [
                                            "Origin": Self.clockURL,
                                            "Referer": Self.clockURL + "/",
                                            "User-Agent": HTTPClient.desktopUserAgent,
                                        ],
                                        subtitles: [],
                                        preferredPeakBitRate: nil
                                    )
                                }
                                return try await HosterResolver(client: client).resolve(stream, referer: clock)
                            }
                        ))
                    } else if let embed = ProviderNetwork.absolute(resolved, relativeTo: baseURL) {
                        links.append(HosterLink(
                            name: name,
                            url: embed,
                            audioLanguage: translation == "dub" ? "en" : "ja"
                        ))
                    }
                }
            }
            if !links.isEmpty { return links }
        }
        return []
    }

    private func api(variables: [String: Any], hash: String, signed: Bool) async throws -> [String: Any] {
        var extensions: [String: Any] = ["persistedQuery": ["version": 1, "sha256Hash": hash]]
        if signed {
            guard let material = try? await MkissaCrypto.material(client: client) else { throw AppError.noStream }
            extensions["k"] = MkissaCrypto.lane
            extensions["aaReq"] = MkissaCrypto.request(key: material.key, epoch: material.epoch, queryHash: hash)
        }
        let endpoint = try url("api", query: [
            "variables": Self.encode(variables),
            "extensions": Self.encode(extensions),
        ])
        return try await jsonObject(endpoint, referer: URL(string: "https://mkissa.to/"), headers: Self.siteHeaders)
    }

    private static func encode(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    /// Source URLs arrive as `--` followed by hex bytes XOR-ed with 56.
    static func decodeSourceURL(_ value: String) -> String? {
        guard !value.isEmpty else { return nil }
        guard value.hasPrefix("--") else { return value }
        let hex = Array(value.dropFirst(2))
        guard hex.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        for index in stride(from: 0, to: hex.count, by: 2) {
            guard let byte = UInt8(String(hex[index...index + 1]), radix: 16) else { return nil }
            bytes.append(byte ^ 56)
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// AllAnime/MKissa client crypto. The mask comes from the shipped build seeds,
/// the lane key from a bootstrap call, and each protected query carries an
/// AES-GCM request token.
enum MkissaCrypto {
    static let lane = "k7"
    static let buildID = "166"

    private static let keyGroup = "mkissa"
    private static let refererHost = "mkissa.to"
    private static let bootPrefix = "ld1faaOf3G:"
    private static let seeds = ["0VmOiOTlfQ0=", "F/SlaG5999I=", "VTm6fMS7BdQ=", "LIQNr2OipeQ="]
    private static let saltMultiplier = 165
    private static let saltAddend = 115
    private static let fragmentMultiplier = 197
    private static let fragmentAddend = 200
    private static let keySize = 16 * 2
    private static let epochMilliseconds = 7 * 24 * 60 * 60 * 1000
    private static let graceMilliseconds = 24 * 60 * 60 * 1000
    private static let requestWindowMilliseconds = 5 * 60 * 1000

    struct Material: Sendable {
        let epoch: Int
        let key: Data
    }

    private actor Cache {
        private var material: Material?
        private var expiry = 0

        func value(now: Int) -> Material? {
            guard let material, now < expiry else { return nil }
            return material
        }

        func store(_ value: Material, expiry: Int) {
            material = value
            self.expiry = expiry
        }
    }

    private static let cache = Cache()

    static func material(client: any HTTPClientProtocol) async throws -> Material {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        if let cached = await cache.value(now: now) { return cached }
        guard let mask = mask() else { throw AppError.noStream }
        for epoch in epochCandidates(now: now) {
            guard let endpoint = URL(string: "https://api.mkissa.net/client-crypto/v1/bootstrap?buildId=\(buildID)&k=\(lane)") else {
                continue
            }
            let response = try? await ProviderNetwork.data(
                client: client,
                url: endpoint,
                referer: URL(string: "https://mkissa.to/"),
                headers: [
                    "Origin": "https://mkissa.to",
                    "x-build-id": buildID,
                    "x-aa-boot": bootToken(mask: mask, epoch: epoch),
                ],
                acceptsJSON: true
            )
            guard let response,
                  let payload = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                  let partB = (payload["partB"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  partB.count >= keySize else { continue }
            let material = Material(epoch: (payload["epoch"] as? Int) ?? epoch, key: key(mask: mask, partB: partB))
            let switchAt = (payload["switchAt"] as? Int) ?? (now + epochMilliseconds)
            await cache.store(material, expiry: min(switchAt, now + epochMilliseconds))
            return material
        }
        throw AppError.noStream
    }

    static func request(key: Data, epoch: Int, queryHash: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000) / requestWindowMilliseconds * requestWindowMilliseconds
        let seed = "\(epoch):\(buildID):\(queryHash):\(timestamp):\(lane)"
        let nonce = Data(SHA256.hash(data: Data(seed.utf8)).prefix(12))
        let payload: [String: Any] = [
            "v": 1, "ts": timestamp, "epoch": epoch, "buildId": buildID, "qh": queryHash, "k": lane,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let box = try? AES.GCM.seal(
                  body,
                  using: SymmetricKey(data: key),
                  nonce: try AES.GCM.Nonce(data: nonce)
              ) else { return "" }
        return (Data([1]) + nonce + box.ciphertext + box.tag).base64EncodedString()
    }

    private static func epochCandidates(now: Int) -> [Int] {
        let current = now / epochMilliseconds
        let inGrace = now - current * epochMilliseconds < graceMilliseconds && current > 0
        return inGrace ? [current - 1, current] : [current]
    }

    private static func mask() -> Data? {
        let identifier = Array(buildID.utf8)
        guard !identifier.isEmpty else { return nil }
        let stream = (0..<keySize).map { index in
            identifier[index % identifier.count] ^ UInt8((index * saltMultiplier + saltAddend) & 0xFF)
        }
        var mask = [UInt8](repeating: 0, count: keySize)
        let fragment = keySize / seeds.count
        for (index, seed) in seeds.enumerated() {
            guard let bytes = Data(base64Encoded: seed), bytes.count >= fragment else { return nil }
            for offset in 0..<fragment {
                mask[index * fragment + offset] = bytes[offset]
                    ^ stream[index * fragment + offset]
                    ^ UInt8((index * fragmentMultiplier + offset * fragmentAddend) & 0xFF)
            }
        }
        return mask.allSatisfy { $0 == 0 } ? nil : Data(mask)
    }

    private static func key(mask: Data, partB: Data) -> Data {
        Data((0..<keySize).map { partB[$0] ^ mask[$0 % mask.count] })
    }

    private static func bootToken(mask: Data, epoch: Int) -> String {
        let inner = HMAC<SHA256>.authenticationCode(
            for: Data("\(bootPrefix)\(buildID)".utf8),
            using: SymmetricKey(data: mask)
        )
        let message = [keyGroup, lane, String(epoch), refererHost, buildID].joined(separator: ":")
        let token = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(inner)))
        return Data(token).map { String(format: "%02x", $0) }.joined()
    }
}
