import Foundation

/// HTTP surface for hoster pages, ported from BetterStreamflix's Android extractors
/// (Apache-2.0). `HTTPClient` rejects every non-2xx response, but hosters routinely
/// answer with a 403 or 404 body that still carries the player payload, so extraction
/// needs the raw response and the post-redirect URL instead.
struct HosterHTTP: Sendable {
    static let shared = HosterHTTP()

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> HosterResponse {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError.invalidResponse }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, let text = value as? String else { continue }
            headers[name.lowercased()] = text
        }
        return HosterResponse(
            data: data,
            url: http.url ?? request.url ?? URL(string: "about:blank")!,
            statusCode: http.statusCode,
            headers: headers
        )
    }

    func get(
        _ url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        acceptsJSON: Bool = false
    ) async throws -> HosterResponse {
        try await send(Self.request(url: url, referer: referer, headers: headers, acceptsJSON: acceptsJSON))
    }

    /// The page body without failing on a soft error status; hoster wrappers often
    /// serve their mirror list alongside a 403.
    func page(_ url: URL, referer: URL? = nil, headers: [String: String] = [:]) async throws -> String {
        let response = try await get(url, referer: referer, headers: headers)
        guard !response.data.isEmpty else { throw AppError.noStream }
        return response.text
    }

    func json(_ url: URL, referer: URL? = nil, headers: [String: String] = [:]) async throws -> Any {
        let response = try await get(url, referer: referer, headers: headers, acceptsJSON: true)
        guard (200...299).contains(response.statusCode) else {
            throw AppError.providerUnavailable("HTTP \(response.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: response.data, options: [.fragmentsAllowed])
    }

    func jsonObject(_ url: URL, referer: URL? = nil, headers: [String: String] = [:]) async throws -> [String: Any] {
        guard let object = try await json(url, referer: referer, headers: headers) as? [String: Any] else {
            throw AppError.invalidResponse
        }
        return object
    }

    var cookieStorage: HTTPCookieStorage {
        Self.session.configuration.httpCookieStorage ?? HTTPCookieStorage.shared
    }

    func cookie(named name: String, for url: URL) -> String? {
        guard let value = cookieStorage.cookies(for: url)?
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value else { return nil }
        return value.removingPercentEncoding ?? value
    }

    static func request(
        url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        acceptsJSON: Bool = false
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(HTTPClient.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("de-DE,de;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            acceptsJSON
                ? "application/json, text/plain, */*"
                : "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        if let referer {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
            request.setValue(referer.origin, forHTTPHeaderField: "Origin")
        }
        if acceptsJSON {
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    static func formRequest(url: URL, referer: URL? = nil, fields: [String: String]) -> URLRequest {
        var request = request(url: url, referer: referer, acceptsJSON: true)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    static func jsonRequest(
        url: URL,
        referer: URL? = nil,
        headers: [String: String] = [:],
        body: [String: Any]
    ) -> URLRequest {
        var request = request(url: url, referer: referer, headers: headers, acceptsJSON: true)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }
}

struct HosterResponse: Sendable {
    let data: Data
    let url: URL
    let statusCode: Int
    let headers: [String: String]

    var text: String { String(decoding: data, as: UTF8.self) }
    func header(_ name: String) -> String? { headers[name.lowercased()] }

    /// Cookies straight off the response. Sites that mint a CSRF pair cannot rely
    /// on the shared jar, which `URLSession` only populates on some platforms.
    var cookies: [HTTPCookie] {
        guard let raw = header("set-cookie") else { return [] }
        return HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url)
    }

    func cookie(named name: String) -> String? {
        guard let value = cookies.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.value else {
            return nil
        }
        return value.removingPercentEncoding ?? value
    }

    var cookieHeader: String? {
        let pairs = cookies.map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }
}

extension URL {
    var origin: String {
        guard let scheme, let host = hostName else { return absoluteString }
        return "\(scheme)://\(host)"
    }

    /// `URL.host` is deprecated on newer SDKs in favour of the percent-decoding variant.
    var hostName: String? {
        host(percentEncoded: false)
    }

    var pathAndQuery: String {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return path }
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath) + query
    }
}

// MARK: - Title matching

/// German catalogues label titles with release junk ("Stream", "(2024)", "S01E02",
/// "Staffel 2"), so provider search results need normalising before comparison.
enum GermanTitleMatching {
    private static let transliterations: [(String, String)] = [
        ("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss"), ("æ", "ae"), ("ø", "oe"), ("å", "aa"),
    ]

    static func normalizeTitle(_ value: String) -> String {
        var lowered = value.lowercased()
        for (character, replacement) in transliterations {
            lowered = lowered.replacingOccurrences(of: character, with: replacement)
        }
        return lowered
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func strippedTitle(_ value: String) -> String {
        var result = value
        let patterns = [
            #"\((?:19|20)\d{2}\)"#,
            #"\bS\d{1,2}\s?E\d{1,3}\b"#,
            #"\b(?:Staffel|Season)\s*\d+\b"#,
            #"\b(?:stream|streaming|kostenlos|online ansehen|deutsch|german|hdfilme|megakino|kinoger)\b"#,
            #"\b(?:1080p|720p|480p|2160p|4k|hdrip|bluray|web-?dl|hdtv)\b"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    static func year(in text: String?) -> Int? {
        guard let text, let match = AnimeHTML.captures(#"\b((?:19|20)\d{2})\b"#, in: text).first else { return nil }
        return Int(match[1])
    }

    static func year(of media: MediaItem) -> Int? { year(in: media.releaseDate) }

    static func seasonNumber(in text: String) -> Int? {
        guard let match = AnimeHTML.captures(#"(?:Staffel|Season)\s*(\d{1,2})"#, in: text).first else { return nil }
        return Int(match[1])
    }

    /// Accepts an exact normalised match, or a whole-word containment in either
    /// direction so "Dune - Part Two Stream" still matches "Dune: Part Two".
    static func matches(_ candidate: String, titles: [String], allowPartial: Bool = true) -> Bool {
        let value = normalizeTitle(strippedTitle(candidate))
        guard !value.isEmpty else { return false }
        for title in titles {
            let wanted = normalizeTitle(title)
            guard wanted.count >= 2 else { continue }
            if value == wanted { return true }
            guard allowPartial else { continue }
            if contains(value, word: wanted) || contains(wanted, word: value) { return true }
        }
        return false
    }

    static func matchesYear(_ candidate: Int?, expected: Int?, tolerance: Int = 1) -> Bool {
        guard let candidate, let expected else { return true }
        return abs(candidate - expected) <= tolerance
    }

    private static func contains(_ haystack: String, word needle: String) -> Bool {
        guard needle.count >= 3, haystack.count > needle.count else { return false }
        return haystack.hasPrefix(needle + " ")
            || haystack.hasSuffix(" " + needle)
            || haystack.contains(" " + needle + " ")
    }
}

// MARK: - Embed wrappers

struct HosterMirror: Sendable, Hashable {
    let name: String
    let url: URL
}

/// Expands meinecloud / devideosrc / firestream embed wrappers into concrete hoster
/// URLs. German providers hand out the wrapper, so playback must never stop there.
enum MeinecloudEmbedHelper {
    static func isMeinecloudURL(_ url: URL) -> Bool {
        let host = url.hostName?.lowercased() ?? ""
        return host.contains("meinecloud") || host.contains("devideosrc")
    }

    static func isFirestreamURL(_ url: URL) -> Bool {
        (url.hostName?.lowercased() ?? "").contains("firestream")
    }

    static func isEmbedWrapper(_ url: URL) -> Bool {
        isMeinecloudURL(url) || isFirestreamURL(url)
    }

    /// `data-link` values are either plain URLs or base64 ("Ly9teGRyb3AudG8v…").
    static func decodeDataLink(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("http") || trimmed.hasPrefix("//") { return trimmed }
        if let data = Data(base64Encoded: padded(trimmed)),
           let decoded = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           decoded.lowercased().hasPrefix("http") || decoded.hasPrefix("//") || decoded.contains(".") {
            return decoded
        }
        return trimmed.contains(".") ? trimmed : nil
    }

    static func normalize(_ raw: String, relativeTo base: URL? = nil) -> URL? {
        let trimmed = HTMLPayloadParser.decodeEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") { return URL(string: "https:" + trimmed) }
        if trimmed.lowercased().hasPrefix("http") { return URL(string: trimmed) }
        if trimmed.hasPrefix("/") { return base.flatMap { URL(string: trimmed, relativeTo: $0)?.absoluteURL } }
        guard trimmed.contains(".") else { return nil }
        return URL(string: "https://" + trimmed)
    }

    static func mirrors(in html: String, base: URL) -> [HosterMirror] {
        let tree = AnimeHTML.parse(html)
        var result: [HosterMirror] = []
        var seen: Set<URL> = []

        func append(_ raw: String, label: String) {
            guard let decoded = decodeDataLink(raw), let url = normalize(decoded, relativeTo: base) else { return }
            let host = url.hostName?.lowercased() ?? ""
            guard !host.contains("youtube"), !host.contains("youtu.be"), url != base else { return }
            guard !seen.contains(url) else { return }
            seen.insert(url)
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            result.append(HosterMirror(name: name.isEmpty ? hosterDisplayName(for: url) : name, url: url))
        }

        for node in tree.all({ !$0["data-link"].isEmpty }) {
            guard !node.hasClass("fullhd"), !node.text.localizedCaseInsensitiveContains("4K Server") else { continue }
            append(node["data-link"], label: node.text)
        }
        if result.isEmpty {
            for node in tree.all({ $0.tag == "iframe" }) {
                append(node["src"].isEmpty ? node["data-src"] : node["src"], label: "Embed")
            }
        }
        return result
    }

    static func expand(_ url: URL, referer: URL? = nil) async -> [HosterMirror] {
        guard let html = try? await HosterHTTP.shared.page(url, referer: referer ?? url) else { return [] }
        return mirrors(in: html, base: url)
    }

    static func hosterDisplayName(for url: URL) -> String {
        let stem = (url.hostName ?? "")
            .lowercased()
            .replacingOccurrences(of: "www.", with: "")
            .components(separatedBy: ".")
            .first ?? ""
        let known = [
            "voe": "Voe", "meinecloud": "Meinecloud", "vidara": "Vidara", "firestream": "Firestream",
            "mixdrop": "Mixdrop", "streamtape": "Streamtape", "streamta": "Streamtape",
            "supervideo": "Supervideo", "vidoza": "Vidoza", "videzz": "Vidoza", "filemoon": "Filemoon",
        ]
        if let name = known[stem] { return name }
        if stem.hasPrefix("dood") || stem == "d000d" || stem == "dsvplay" || stem == "vide0" { return "Doodstream" }
        guard let first = stem.first else { return "Server" }
        return first.uppercased() + stem.dropFirst()
    }

    private static func padded(_ value: String) -> String {
        let compact = value.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
    }
}

// MARK: - Hoster extraction

/// Resolves a hoster embed URL to a playable source. Ported from the Android
/// extractors: DoodStream (`DoodLaExtractor`), VOE (`VoeExtractor` + `DecryptHelper`),
/// Streamtape, Vidoza and the meinecloud embed wrappers.
enum HosterExtractor {
    static func resolve(
        _ url: URL,
        referer: URL?,
        serverName: String = "",
        depth: Int = 0
    ) async throws -> PlaybackSource {
        guard depth < 3, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw AppError.noStream }
        if let direct = directSource(url, referer: referer) { return direct }

        let host = url.hostName?.lowercased() ?? ""
        let hint = serverName.lowercased()

        if MeinecloudEmbedHelper.isEmbedWrapper(url) {
            return try await meinecloud(url, referer: referer, depth: depth)
        }
        if isDoodHost(host) || hint.contains("dood") {
            return try await doodStream(url)
        }
        if isVoeHost(host) || hint.contains("voe") {
            return try await voe(url)
        }
        if host.contains("streamtape") || host.contains("streamta") || hint.contains("streamtape") {
            return try await streamtape(url)
        }
        if host.contains("vidoza") || host.contains("videzz") || hint.contains("vidoza") {
            return try await vidoza(url)
        }
        if host.contains("vidara") || hint.contains("vidara") {
            return try await vidara(url)
        }
        return try await generic(url, referer: referer, depth: depth)
    }

    static func resolveFirst(_ mirrors: [HosterMirror], referer: URL?) async throws -> PlaybackSource {
        var lastError: (any Error)?
        for mirror in mirrors {
            try Task.checkCancellation()
            do { return try await resolve(mirror.url, referer: referer, serverName: mirror.name) }
            catch where error.isCancellation { throw error }
            catch { lastError = error }
        }
        throw lastError ?? AppError.noStream
    }

    static func headers(referer: URL?, origin: URL? = nil) -> [String: String] {
        var result = ["User-Agent": HTTPClient.desktopUserAgent]
        if let referer {
            result["Referer"] = referer.absoluteString
            result["Origin"] = (origin ?? referer).origin
        }
        return result
    }

    static func directSource(_ url: URL, referer: URL?) -> PlaybackSource? {
        let path = url.path.lowercased()
        guard path.hasSuffix(".m3u8") || path.hasSuffix(".mp4") || path.hasSuffix(".mpd") else { return nil }
        return PlaybackSource(
            url: url,
            headers: headers(referer: referer ?? url),
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    // MARK: DoodStream

    private static let doodAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    static func isDoodHost(_ host: String) -> Bool {
        let stems = ["dood", "d000d", "dsvplay", "myvidplay", "playmogo", "do7go", "vide0.net", "ds2play", "doply"]
        return stems.contains { host.contains($0) }
    }

    /// `/d/` is the share page and `/e/` the embed; the embed body carries the
    /// `/pass_md5/` path whose response is the URL prefix for a random 10-char suffix.
    static func doodStream(_ link: URL) async throws -> PlaybackSource {
        guard let embed = URL(string: link.absoluteString.replacingOccurrences(of: "/d/", with: "/e/")) else {
            throw AppError.invalidURL
        }
        let response = try await HosterHTTP.shared.get(embed, referer: link)
        let finalURL = response.url
        guard let base = URL(string: finalURL.origin) else { throw AppError.invalidURL }
        guard let md5Path = AnimeHTML.captures(#"/pass_md5/[^'"\s]+"#, in: response.text).first?[0],
              let md5URL = URL(string: base.absoluteString + md5Path) else { throw AppError.noStream }

        let prefix = try await HosterHTTP.shared.page(md5URL, referer: finalURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { throw AppError.noStream }

        let token = md5URL.absoluteString.components(separatedBy: "/").last ?? ""
        let suffix = String((0..<10).compactMap { _ in doodAlphabet.randomElement() })
        guard let source = URL(string: prefix + suffix + "?token=" + token) else { throw AppError.invalidURL }
        return PlaybackSource(
            url: source,
            headers: ["Referer": base.absoluteString, "User-Agent": HTTPClient.desktopUserAgent],
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    // MARK: VOE

    static func isVoeHost(_ host: String) -> Bool {
        host == "voe.sx" || host.hasPrefix("voe.") || host.contains("voe-unblock")
            || host.contains("voeunblock") || host.contains("voeun-block") || host.contains("unblockvoe")
    }

    /// VOE rotates hostnames: the first page is a stub whose body names the live
    /// domain, and the payload is an obfuscated JSON blob (see `decryptVOEPayload`).
    static func voe(_ link: URL) async throws -> PlaybackSource {
        var attempted: Set<URL> = []
        var pages: [URL] = [link]
        if let canonical = URL(string: "https://voe.sx" + link.pathAndQuery), canonical != link {
            pages.append(canonical)
        }

        var index = 0
        while index < pages.count, index < 4 {
            let page = pages[index]
            index += 1
            guard !attempted.contains(page) else { continue }
            attempted.insert(page)

            guard let html = try? await HosterHTTP.shared.page(page, referer: link) else { continue }
            if let payload = decryptVOEPayload(in: html) {
                return try voeSource(payload, html: html, link: page)
            }
            // The stub page only advertises the live rotating host.
            if let host = AnimeHTML.captures(#"https://([a-zA-Z0-9.\-]+)"#, in: html).first?[1],
               host.lowercased() != page.hostName?.lowercased(),
               let next = URL(string: "https://" + host + link.pathAndQuery) {
                pages.append(next)
            }
        }
        throw AppError.noStream
    }

    private static func voeSource(_ payload: [String: Any], html: String, link: URL) throws -> PlaybackSource {
        guard let file = payload["source"] as? String ?? payload["file"] as? String,
              let source = URL(string: file.replacingOccurrences(of: "\\/", with: "/")) else { throw AppError.noStream }
        let base = AnimeHTML.captures(#"var\s+base\s*=\s*['"]([^'"]+)['"]"#, in: html).first?[1] ?? ""
        let headers = [
            "Referer": link.absoluteString,
            "Origin": link.origin,
            "User-Agent": HTTPClient.desktopUserAgent,
        ]
        let subtitles = (payload["captions"] as? [[String: Any]] ?? []).compactMap { caption -> SubtitleSource? in
            guard let file = caption["file"] as? String, !file.isEmpty else { return nil }
            let absolute = file.lowercased().hasPrefix("http") ? file : base + file
            guard let url = URL(string: absolute, relativeTo: link)?.absoluteURL else { return nil }
            let label = caption["label"] as? String ?? "Untertitel"
            return SubtitleSource(
                providerID: "voe",
                providerName: "VOE",
                label: label,
                languageCode: AnimeStreamResolver.languageCode(label),
                url: url,
                isDefault: caption["default"] as? Bool ?? false,
                headers: headers
            )
        }
        return PlaybackSource(url: source, headers: headers, subtitles: subtitles, preferredPeakBitRate: nil)
    }

    /// Ported from `DecryptHelper.decryptF7`: rot13 → separator substitution →
    /// underscore removal → base64 → shift every scalar down by 3 → reverse → base64.
    static func decryptVOEPayload(in html: String) -> [String: Any]? {
        var encoded: [String] = []
        for match in AnimeHTML.captures(#"<script[^>]+type=["']application/json["'][^>]*>([\s\S]*?)</script>"#, in: html) {
            encoded.append(match[1])
        }
        for candidate in encoded {
            if let payload = decryptVOEString(candidate) { return payload }
        }
        return nil
    }

    static func decryptVOEString(_ encoded: String) -> [String: Any]? {
        var value = encoded.trimmingCharacters(in: .whitespacesAndNewlines)
        // The script tag usually wraps the payload in a single-element JSON array.
        if value.hasPrefix("["),
           let data = value.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
           let first = array.compactMap({ $0 as? String }).first {
            value = first
        }
        guard !value.isEmpty else { return nil }

        var stage = rot13(value)
        for pattern in ["@$", "^^", "~@", "%?", "*~", "!!", "#&"] {
            stage = stage.replacingOccurrences(of: pattern, with: "_")
        }
        stage = stage.replacingOccurrences(of: "_", with: "")
        guard let decoded = base64Decoded(stage) else { return nil }
        let shifted = String(String.UnicodeScalarView(decoded.unicodeScalars.compactMap { scalar in
            scalar.value >= 3 ? UnicodeScalar(scalar.value - 3) : scalar
        }))
        guard let payload = base64Decoded(String(shifted.reversed())),
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func rot13(_ value: String) -> String {
        String(value.map { character in
            guard let ascii = character.asciiValue else { return character }
            switch ascii {
            case 65...90: return Character(UnicodeScalar((ascii - 65 + 13) % 26 + 65))
            case 97...122: return Character(UnicodeScalar((ascii - 97 + 13) % 26 + 97))
            default: return character
            }
        })
    }

    private static func base64Decoded(_ value: String) -> String? {
        let compact = value.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = compact + String(repeating: "=", count: (4 - compact.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: [.ignoreUnknownCharacters]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Streamtape

    /// The page hides the `get_video` query in a two-part JS concatenation whose
    /// second half must be offset by the `substring(n)` literal.
    static func streamtape(_ link: URL) async throws -> PlaybackSource {
        let html = try await HosterHTTP.shared.page(link, referer: link)
        let pattern = #"getElementById\('botlink'\)\.innerHTML\s*=\s*'([^']+)'\s*\+\s*\('([^']+)'\)\.substring\((\d+)\)"#
        guard let match = AnimeHTML.captures(pattern, in: html).first,
              let offset = Int(match[3]), match[2].count >= offset else { throw AppError.noStream }
        let parameters = String(match[2].dropFirst(offset))

        func value(_ name: String) -> String? {
            AnimeHTML.captures(name + #"=([^&]+)"#, in: parameters).first?[1]
        }

        let videoURL: URL?
        if let id = value("id"), let expires = value("expires"), let ip = value("ip"), let token = value("token") {
            videoURL = URL(string: "https://streamtape.com/get_video?id=\(id)&expires=\(expires)&ip=\(ip)&token=\(token)&stream=1")
        } else {
            videoURL = MeinecloudEmbedHelper.normalize(match[1] + parameters + "&stream=1", relativeTo: link)
        }
        guard let videoURL else { throw AppError.noStream }

        // The endpoint redirects to the CDN; a one-byte range keeps the body off the wire.
        let response = try await HosterHTTP.shared.get(videoURL, referer: link, headers: ["Range": "bytes=0-0"])
        guard response.url != videoURL else { throw AppError.noStream }
        return PlaybackSource(
            url: response.url,
            headers: ["Referer": link.origin + "/", "User-Agent": HTTPClient.desktopUserAgent],
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    // MARK: Vidoza

    static func vidoza(_ link: URL) async throws -> PlaybackSource {
        let html = try await HosterHTTP.shared.page(link, referer: link)
        let candidates = [
            AnimeHTML.parse(html).first { $0.tag == "source" && !$0["src"].isEmpty }?["src"],
            AnimeHTML.captures(#"sourcesCode\s*:\s*\[\s*\{\s*src\s*:\s*["']([^"']+)["']"#, in: html).first?[1],
            AnimeHTML.captures(#"["']?(?:src|file)["']?\s*[:=]\s*["'](https?://[^"']+\.(?:mp4|m3u8)[^"']*)["']"#, in: html).first?[1],
        ]
        guard let raw = candidates.compactMap({ $0 }).first(where: { !$0.isEmpty }),
              let source = URL(string: raw.replacingOccurrences(of: "\\/", with: "/"), relativeTo: link)?.absoluteURL else {
            throw AppError.noStream
        }
        return PlaybackSource(
            url: source,
            headers: ["Referer": link.absoluteString, "Origin": link.origin, "User-Agent": HTTPClient.desktopUserAgent],
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    // MARK: Vidara

    /// Ported from `VidaraExtractor`. The embed page is an empty player shell and
    /// the real URL comes back from `POST {origin}/api/stream`, keyed on the file
    /// code from the path. Deriving the origin from the link rather than a host
    /// list is what keeps the rotating mirror domains working.
    static func vidara(_ link: URL) async throws -> PlaybackSource {
        guard let code = link.pathComponents.last(where: { !$0.isEmpty && $0 != "/" }),
              let api = URL(string: link.origin + "/api/stream") else { throw AppError.noStream }
        let request = HosterHTTP.jsonRequest(url: api, referer: link, body: ["filecode": code, "device": "web"])
        let response = try await HosterHTTP.shared.send(request)
        guard let payload = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let raw = payload["streaming_url"] as? String,
              let source = URL(string: raw.replacingOccurrences(of: "\\/", with: "/")) else {
            throw AppError.noStream
        }

        let headers = [
            "Referer": link.origin + "/",
            "Origin": link.origin,
            "User-Agent": HTTPClient.desktopUserAgent,
        ]
        let preferred = payload["default_sub_lang"] as? String ?? ""
        var claimedDefault = false
        let subtitles = (payload["subtitles"] as? [[String: Any]] ?? []).compactMap { entry -> SubtitleSource? in
            guard let path = entry["file_path"] as? String, !path.isEmpty,
                  let url = URL(string: path, relativeTo: link)?.absoluteURL else { return nil }
            let label = entry["language"] as? String ?? "Untertitel"
            let isDefault = !claimedDefault && !preferred.isEmpty && label.contains(preferred)
            if isDefault { claimedDefault = true }
            return SubtitleSource(
                providerID: "vidara",
                providerName: "Vidara",
                label: label,
                languageCode: AnimeStreamResolver.languageCode(label),
                url: url,
                isDefault: isDefault,
                headers: headers
            )
        }
        return PlaybackSource(url: source, headers: headers, subtitles: subtitles, preferredPeakBitRate: nil)
    }

    /// The Vidara player software identifies itself in the shell it serves, which
    /// is the only way to spot a mirror whose domain nobody has seen before.
    static func looksLikeVidara(_ html: String) -> Bool {
        html.contains("api/stream") && html.contains("filecode")
    }

    // MARK: Embed wrappers and generic pages

    static func meinecloud(_ link: URL, referer: URL?, depth: Int) async throws -> PlaybackSource {
        let mirrors = await MeinecloudEmbedHelper.expand(link, referer: referer)
            .filter { !MeinecloudEmbedHelper.isEmbedWrapper($0.url) }
        var lastError: (any Error)?
        for mirror in mirrors {
            try Task.checkCancellation()
            do { return try await resolve(mirror.url, referer: link, serverName: mirror.name, depth: depth + 1) }
            catch where error.isCancellation { throw error }
            catch { lastError = error }
        }
        if let packed = try? await generic(link, referer: referer, depth: depth + 1) { return packed }
        throw lastError ?? AppError.noStream
    }

    /// Last resort for hosters without a dedicated port: a plain HTML5 source, an
    /// inline playlist URL, a VOE-style payload, or a nested player iframe.
    static func generic(_ link: URL, referer: URL?, depth: Int) async throws -> PlaybackSource {
        let html = try await HosterHTTP.shared.page(link, referer: referer ?? link)
        if let payload = decryptVOEPayload(in: html) {
            return try voeSource(payload, html: html, link: link)
        }
        if looksLikeVidara(html), let source = try? await vidara(link) { return source }
        let tree = AnimeHTML.parse(html)
        if let node = tree.first({ ($0.tag == "source" || $0.tag == "video") && !$0["src"].isEmpty }),
           let url = URL(string: node["src"], relativeTo: link)?.absoluteURL,
           let direct = directSource(url, referer: link) {
            return direct
        }
        if let raw = playlistURL(in: html), let url = URL(string: raw, relativeTo: link)?.absoluteURL {
            return PlaybackSource(
                url: url,
                headers: headers(referer: link),
                subtitles: [],
                preferredPeakBitRate: nil
            )
        }
        for node in tree.all({ $0.tag == "iframe" }) {
            try Task.checkCancellation()
            let source = node["src"].isEmpty ? node["data-src"] : node["src"]
            guard let child = MeinecloudEmbedHelper.normalize(source, relativeTo: link),
                  child != link,
                  !(child.hostName ?? "").contains("youtube") else { continue }
            if let resolved = try? await resolve(child, referer: link, depth: depth + 1) { return resolved }
        }
        throw AppError.noStream
    }

    static func playlistURL(in html: String) -> String? {
        let decoded = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\x26", with: "&")
        let patterns = [
            #"["']?file["']?\s*[:=]\s*["'](https?://[^"']+\.(?:m3u8|mp4)[^"']*)["']"#,
            #"["']?src["']?\s*[:=]\s*["'](https?://[^"']+\.(?:m3u8|mp4)[^"']*)["']"#,
            #"(https?://[^"'\s\\]+\.m3u8[^"'\s\\]*)"#,
            #"(https?://[^"'\s\\]+\.mp4[^"'\s\\]*)"#,
        ]
        for pattern in patterns {
            if let value = AnimeHTML.captures(pattern, in: decoded).first?[1], !value.isEmpty { return value }
        }
        return nil
    }
}
