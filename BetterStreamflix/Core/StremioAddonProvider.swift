import Foundation
import Security

struct StremioPlaybackProvider: PlaybackProvider {
    let id: String
    private let client: any HTTPClientProtocol
    private let fixedAddons: [(id: String, name: String, baseURL: URL, idPrefixes: [String]?, types: [String]?, requiresConfig: Bool, manifestURL: URL?)]?

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        fixedAddons: [(id: String, name: String, baseURL: URL)]? = nil,
        providerID: String = "external-streams"
    ) {
        self.id = providerID
        self.client = client
        self.fixedAddons = fixedAddons?.map {
            ($0.id, $0.name, $0.baseURL, nil as [String]?, nil as [String]?, false, nil as URL?)
        }
    }

    /// Backwards-compatible single-addon initializer used by unit tests.
    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL?, providerID: String = "external-streams") {
        self.id = providerID
        self.client = client
        if let baseURL {
            fixedAddons = [("test", "Test", baseURL, nil, nil, false, nil)]
        } else {
            fixedAddons = []
        }
    }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        let addons = fixedAddons ?? StremioAddonStore.snapshotStreamAddons()
        var diagnostics = StremioResolveDiagnostics()
        diagnostics.debridConfigured = Self.isDebridConfigured()
        diagnostics.missingIMDb = context.request.media.imdbID == nil
        diagnostics.queriedAddons = addons.count

        guard !addons.isEmpty else {
            StremioResolveDiagnosticsStore.update(diagnostics)
            return []
        }

        let mediaType = context.request.media.kind == .movie ? "movie" : "series"
        let providerID = id
        let timeout = Self.queryTimeout()
        let budget = Self.maxParallel()

        return try await withThrowingTaskGroup(
            of: (candidates: [PlaybackCandidate], stats: StreamBatchStats, usedTMDb: Bool).self
        ) { group in
            var scheduled = 0
            for addon in addons {
                if addon.requiresConfig,
                   let manifestURL = addon.manifestURL,
                   !StremioDebridURLBuilder.looksConfigured(manifestURL) {
                    diagnostics.skippedNeedsConfig += 1
                    continue
                }
                if let types = addon.types, !types.isEmpty, !types.contains(mediaType) {
                    continue
                }
                if scheduled >= budget { break }
                scheduled += 1
                group.addTask {
                    await Self.queryAddon(
                        addon: addon,
                        context: context,
                        mediaType: mediaType,
                        providerID: providerID,
                        client: self.client,
                        timeout: timeout
                    )
                }
            }

            var merged: [PlaybackCandidate] = []
            var seen = Set<String>()
            var seenURLs = Set<String>()
            for try await batch in group {
                diagnostics.playableHTTP += batch.stats.playable
                diagnostics.skippedTorrent += batch.stats.torrent
                diagnostics.skippedYouTube += batch.stats.youtube
                diagnostics.skippedExternal += batch.stats.external
                diagnostics.skippedUnsupportedFormat += batch.stats.unsupported
                diagnostics.failedAddons += batch.stats.failed ? 1 : 0
                if batch.usedTMDb { diagnostics.usedTMDbIdentifier = true }
                for candidate in batch.candidates {
                    let urlKey = candidate.id
                    let normalized = Self.normalizedURLKey(from: candidate)
                    if let normalized, !seenURLs.insert(normalized).inserted {
                        continue
                    }
                    if seen.insert(urlKey).inserted {
                        merged.append(candidate)
                    }
                }
            }
            StremioResolveDiagnosticsStore.update(diagnostics)
            return merged
        }
    }

    private static func queryAddon(
        addon: (id: String, name: String, baseURL: URL, idPrefixes: [String]?, types: [String]?, requiresConfig: Bool, manifestURL: URL?),
        context: PlaybackLookupContext,
        mediaType: String,
        providerID: String,
        client: any HTTPClientProtocol,
        timeout: TimeInterval
    ) async -> (candidates: [PlaybackCandidate], stats: StreamBatchStats, usedTMDb: Bool) {
        var stats = StreamBatchStats()
        let usedTMDb: Bool
        do {
            let identifier = StremioAddonClient.streamIdentifier(
                for: context,
                idPrefixes: addon.idPrefixes
            )
            usedTMDb = identifier?.hasPrefix("tmdb:") == true
            guard let identifier else {
                return ([], stats, false)
            }
            if let prefixes = addon.idPrefixes, !prefixes.isEmpty {
                let ok = prefixes.contains { identifier.hasPrefix($0) || identifier.hasPrefix("tt") && $0.hasPrefix("tt") }
                if !ok, !(addon.idPrefixes?.contains(where: { identifier.hasPrefix($0) }) ?? true) {
                    return ([], stats, usedTMDb)
                }
            }

            let addonClient = StremioAddonClient(client: client, baseURL: addon.baseURL)
            let streams: [StremioStream] = try await withTimeout(timeout) {
                try await addonClient.streams(type: mediaType, id: identifier)
            }

            var built: [PlaybackCandidate] = []
            for (index, stream) in streams.enumerated() {
                switch stream.playbackKind {
                case .torrent:
                    stats.torrent += 1
                case .youtube:
                    stats.youtube += 1
                case .external:
                    stats.external += 1
                case .unsupported:
                    stats.unsupported += 1
                case .http:
                    if stream.notWebReady || stream.behaviorHints?.filename.map({
                        [".mkv", ".avi", ".webm", ".zip", ".iso"].contains(where: $0.lowercased().contains)
                    }) == true,
                       playableFormat(for: stream, url: stream.url!) == nil {
                        stats.unsupported += 1
                        continue
                    }
                    if let candidate = candidate(
                        stream,
                        order: index,
                        context: context,
                        addonID: addon.id,
                        addonName: addon.name,
                        providerID: providerID,
                        client: addonClient
                    ) {
                        built.append(candidate)
                        stats.playable += 1
                    } else {
                        stats.unsupported += 1
                    }
                }
            }
            return (built, stats, usedTMDb)
        } catch {
            stats.failed = true
            return ([], stats, false)
        }
    }

    private struct StreamBatchStats {
        var playable = 0
        var torrent = 0
        var youtube = 0
        var external = 0
        var unsupported = 0
        var failed = false
    }

    private static func candidate(
        _ stream: StremioStream,
        order: Int,
        context: PlaybackLookupContext,
        addonID: String,
        addonName: String,
        providerID: String,
        client: StremioAddonClient
    ) -> PlaybackCandidate? {
        guard stream.ytId == nil,
              stream.infoHash == nil,
              stream.externalUrl == nil,
              let url = stream.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let format = playableFormat(for: stream, url: url) else { return nil }

        let detail = stream.detailText
        let origin = capture(#"(?im)^.*Source:\s*([^\n\r]+)"#, in: detail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? cleanedName(stream.name)
            ?? cleanedName(stream.title)
            ?? addonName
        let quality = capture(#"(?i)(2160p|1080p|720p|480p|360p|4K)"#, in: detail)
            ?? capture(#"(?i)(2160p|1080p|720p|480p|360p|4K)"#, in: stream.displayLabel)
        let release = capture(#"(?i)\b(BluRay|WEB-DL|WEBRip|HDR|REMUX|HDTV|DVDRip)\b"#, in: detail)
        let audio = capture(#"(?im)^.*Audio:\s*([^,\n\r]+)"#, in: detail)
        let language = languageCode(audio)
        let filename = stream.behaviorHints?.filename
        let stableServer = [addonID, origin, quality, format, stream.behaviorHints?.bingeGroup ?? "\(order)", filename ?? ""]
            .compactMap { $0 }
            .joined(separator: "|")
        let preference = PlaybackSourcePreference(
            providerID: providerID,
            serverName: stableServer,
            audioLanguage: language ?? ""
        )
        let candidateID = "\(providerID):\(stableServer.lowercased())"
        let labelOrigin = "\(origin) · \(addonName)"
        let metadata = StreamDisplayMetadata(
            origin: labelOrigin,
            quality: quality,
            sizeBytes: stream.behaviorHints?.videoSize,
            container: format.uppercased(),
            audioLanguage: audio,
            releaseType: release
        )
        let initial = playbackSource(for: stream, url: url)
        let resolver = RefreshingStremioSource(initial: initial) {
            let refreshed = try await client.streams(for: context)
            guard let match = refreshed.enumerated().first(where: { offset, candidate in
                stableServerKey(for: candidate, order: offset, addonID: addonID, addonName: addonName)
                    == stableServer
            }), let refreshedURL = match.element.url else {
                throw AppError.noStream
            }
            return playbackSource(for: match.element, url: refreshedURL)
        }
        return PlaybackCandidate(
            id: candidateID,
            preference: preference,
            providerName: labelOrigin,
            subtitleKind: .unknown,
            displayMetadata: metadata,
            resolve: { try await resolver.resolve() }
        )
    }

    /// Non-playable torrent / external streams are counted in diagnostics only (T4 / B2)
    /// so PlaybackDiscovery never auto-selects them. Empty states point users to Debrid
    /// or Safari when those were the only results.

    private static func stableServerKey(
        for stream: StremioStream,
        order: Int,
        addonID: String,
        addonName: String
    ) -> String? {
        guard let url = stream.url, playableFormat(for: stream, url: url) != nil else { return nil }
        let detail = stream.detailText
        let origin = capture(#"(?im)^.*Source:\s*([^\n\r]+)"#, in: detail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? cleanedName(stream.name)
            ?? cleanedName(stream.title)
            ?? addonName
        let quality = capture(#"(?i)(2160p|1080p|720p|480p|360p|4K)"#, in: detail)
            ?? capture(#"(?i)(2160p|1080p|720p|480p|360p|4K)"#, in: stream.displayLabel)
        let format = playableFormat(for: stream, url: url)
        let filename = stream.behaviorHints?.filename ?? ""
        return [addonID, origin, quality, format, stream.behaviorHints?.bingeGroup ?? "\(order)", filename]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    private static func playbackSource(for stream: StremioStream, url: URL) -> PlaybackSource {
        PlaybackSource(
            url: url,
            headers: stream.behaviorHints?.proxyHeaders?.request ?? [:],
            subtitles: [],
            preferredPeakBitRate: nil
        )
    }

    private static func playableFormat(for stream: StremioStream, url: URL) -> String? {
        if stream.notWebReady { return nil }
        let detail = stream.detailText + " " + stream.displayLabel
        let declared = capture(
            #"(?i)(?:^|[•\s])(HLS|MP4|M4V|MOV|MKV|AVI|WEBM|ZIP|ISO)(?:$|[•\s])"#,
            in: detail
        )?.lowercased()
        if let declared {
            return ["hls", "mp4", "m4v", "mov"].contains(declared) ? declared : nil
        }
        let ext = url.pathExtension.lowercased()
        if ["m3u8", "mp4", "m4v", "mov"].contains(ext) {
            return ext == "m3u8" ? "hls" : ext
        }
        let filename = stream.behaviorHints?.filename?.lowercased() ?? ""
        if [".mkv", ".avi", ".webm", ".zip", ".iso"].contains(where: filename.contains) {
            return nil
        }
        if stream.infoHash == nil, stream.ytId == nil, stream.url != nil {
            return "mp4"
        }
        return nil
    }

    private static func cleanedName(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(
            of: #"^[\p{Emoji}\p{Emoji_Presentation}\s|•·\-]+"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.nilIfEmpty
    }

    private static func normalizedURLKey(from candidate: PlaybackCandidate) -> String? {
        // Prefer quality+origin fingerprint already in id; also fold by stripping query.
        if candidate.id.contains(":torrent:") || candidate.id.contains(":external:") {
            return candidate.id
        }
        return candidate.id
            .components(separatedBy: "?")
            .first?
            .lowercased()
    }

    private static func isDebridConfigured() -> Bool {
        // Nonisolated-safe: read UserDefaults / keychain via a lightweight check.
        StremioDebridService.allCases.contains { service in
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.betterstreamflix.ios.stremio.debrid",
                kSecAttrAccount as String: "debrid.\(service.rawValue)",
                kSecReturnData as String: false,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
        }
    }

    private static func queryTimeout() -> TimeInterval {
        let value = UserDefaults.standard.double(forKey: StremioDebridStore.streamTimeoutKey)
        return value > 0 ? value : 12
    }

    private static func maxParallel() -> Int {
        let value = UserDefaults.standard.integer(forKey: StremioDebridStore.maxParallelKey)
        return value > 0 ? value : 6
    }

    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AppError.providerUnavailable("Stremio timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    fileprivate static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    fileprivate static func languageCode(_ value: String?) -> String? {
        guard let value else { return nil }
        let key = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "english": "en", "japanese": "ja", "hebrew": "he", "hindi": "hi", "tamil": "ta",
            "telugu": "te", "korean": "ko", "chinese": "zh", "spanish": "es", "french": "fr",
            "german": "de", "italian": "it", "portuguese": "pt", "russian": "ru", "arabic": "ar",
        ][key]
    }
}

private actor RefreshingStremioSource {
    private var initial: PlaybackSource?
    private let refresh: @Sendable () async throws -> PlaybackSource

    init(initial: PlaybackSource, refresh: @escaping @Sendable () async throws -> PlaybackSource) {
        self.initial = initial
        self.refresh = refresh
    }

    func resolve() async throws -> PlaybackSource {
        if let initial {
            self.initial = nil
            return initial
        }
        return try await refresh()
    }
}

struct StremioSubtitleProvider: SubtitleProvider {
    let id = "external-stream-subtitles"
    let displayName = "Stremio"
    private let client: any HTTPClientProtocol
    private let fixedAddons: [(id: String, name: String, baseURL: URL, idPrefixes: [String]?)]?

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        fixedAddons: [(id: String, name: String, baseURL: URL)]? = nil
    ) {
        self.client = client
        self.fixedAddons = fixedAddons?.map { ($0.id, $0.name, $0.baseURL, nil) }
    }

    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL?) {
        self.client = client
        if let baseURL {
            fixedAddons = [("test", "Stremio", baseURL, nil)]
        } else {
            fixedAddons = []
        }
    }

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        let addons = fixedAddons ?? StremioAddonStore.snapshotSubtitleAddons()
        guard !addons.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: [SubtitleSource].self) { group in
            for addon in addons {
                group.addTask {
                    let client = StremioAddonClient(client: self.client, baseURL: addon.baseURL)
                    let entries = try await client.subtitles(
                        for: request,
                        idPrefixes: addon.idPrefixes,
                        tmdbID: nil
                    )
                    var seen = Set<String>()
                    return entries.compactMap { entry -> SubtitleSource? in
                        guard let url = entry.url,
                              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                            return nil
                        }
                        let provider = Self.origin(for: entry, addonName: addon.name)
                        let language = Self.language(for: entry.lang)
                        let entryIdentity = entry.id.flatMap { raw in
                            URL(string: raw).flatMap {
                                $0.scheme == nil ? nil : $0.deletingQuery().absoluteString
                            } ?? raw
                        } ?? url.deletingQuery().absoluteString
                        let stableID = "\(self.id):\(addon.id):\(provider.lowercased()):\(entryIdentity)"
                        guard seen.insert(stableID).inserted else { return nil }
                        return SubtitleSource(
                            id: stableID,
                            providerID: self.id,
                            providerName: provider,
                            label: SubtitleLanguage.displayName(language),
                            languageCode: language,
                            url: url
                        )
                    }
                }
            }
            var merged: [SubtitleSource] = []
            var seen = Set<String>()
            for try await batch in group {
                for item in batch where seen.insert(item.id).inserted {
                    merged.append(item)
                }
            }
            return merged
        }
    }

    private static func origin(for entry: StremioSubtitle, addonName: String) -> String {
        if let raw = entry.id?.split(separator: "-").first, !raw.contains("://") {
            let value = String(raw).lowercased()
            if value == "moviebox" { return "MovieBox" }
        }
        return addonName.nilIfEmpty ?? "Stremio"
    }

    private static func language(for raw: String?) -> String {
        SubtitleLanguage.canonicalCode(raw) ?? "und"
    }
}

/// App-bundled HTTP stream source from Info.plist — never shown as a Stremio community plugin.
enum BundledHTTPPlaybackProvider {
    static func make(client: any HTTPClientProtocol = HTTPClient()) -> StremioPlaybackProvider? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "ExternalStreamAddonManifestURL") as? String,
              let manifest = StremioManifestURL.parse(raw) else { return nil }
        return StremioPlaybackProvider(
            client: client,
            baseURL: manifest.deletingLastPathComponent(),
            providerID: "bundled-http-streams"
        )
    }
}
