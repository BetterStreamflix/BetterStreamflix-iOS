import Foundation
import Security

struct StremioPlaybackProvider: PlaybackProvider {
    let id: String
    private let client: any HTTPClientProtocol
    private let fixedAddons: [(id: String, name: String, baseURL: URL, idPrefixes: [String]?, types: [String]?, requiresConfig: Bool, manifestURL: URL?, health: StremioAddonHealth)]?

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        fixedAddons: [(id: String, name: String, baseURL: URL)]? = nil,
        providerID: String = "external-streams"
    ) {
        self.id = providerID
        self.client = client
        self.fixedAddons = fixedAddons?.map {
            ($0.id, $0.name, $0.baseURL, nil as [String]?, nil as [String]?, false, nil as URL?, StremioAddonHealth.unknown)
        }
    }

    /// Backwards-compatible single-addon initializer used by unit tests.
    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL?, providerID: String = "external-streams") {
        self.id = providerID
        self.client = client
        if let baseURL {
            fixedAddons = [("test", "Test", baseURL, nil, nil, false, nil, .unknown)]
        } else {
            fixedAddons = []
        }
    }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        let cacheKey = StremioStreamSessionCache.cacheKey(for: context)
        if let cached = await StremioStreamSessionCache.shared.candidates(for: cacheKey), !cached.isEmpty {
            return cached
        }

        let allAddons = fixedAddons ?? StremioAddonStore.snapshotStreamAddons()
        // Soft-skip known-unreachable hosts on the first pass; retry if nothing playable.
        let primaryAddons = allAddons.filter { $0.health != .unreachable }
        let deferredAddons = allAddons.filter { $0.health == .unreachable }
        let addons = primaryAddons.isEmpty ? allAddons : primaryAddons
        var diagnostics = StremioResolveDiagnostics()
        diagnostics.debridConfigured = Self.isDebridConfigured()
        diagnostics.missingIMDb = context.request.media.imdbID == nil
        diagnostics.queriedAddons = allAddons.count

        let showID = context.request.media.id
        let preferredBinge = StremioBingeContinuityStore.preferredGroup(forShowID: showID)
        diagnostics.continuingBingeGroup = preferredBinge

        guard !allAddons.isEmpty else {
            StremioResolveDiagnosticsStore.update(diagnostics)
            return []
        }

        let mediaType = context.request.media.kind == .movie ? "movie" : "series"
        let providerID = id
        let timeout = Self.queryTimeout()
        let budget = Self.maxParallel()

        // Concurrent pool: schedule all eligible addons, but never exceed `budget` in-flight.
        return try await withThrowingTaskGroup(
            of: (candidates: [PlaybackCandidate], stats: StreamBatchStats, usedTMDb: Bool, progress: StremioAddonResolveProgress).self
        ) { group in
            var scheduled = 0
            var inFlight = 0
            var iterator = addons.makeIterator()
            var progressRows: [StremioAddonResolveProgress] = []

            func enqueueNext() {
                while inFlight < budget, let addon = iterator.next() {
                    if addon.requiresConfig,
                       let manifestURL = addon.manifestURL,
                       !StremioDebridURLBuilder.looksConfigured(manifestURL) {
                        diagnostics.skippedNeedsConfig += 1
                        progressRows.append(
                            StremioAddonResolveProgress(
                                addonID: addon.id,
                                addonName: addon.name,
                                status: .skippedConfig,
                                playable: 0,
                                skippedTorrent: 0,
                                latencyMS: nil
                            )
                        )
                        continue
                    }
                    if let types = addon.types, !types.isEmpty, !types.contains(mediaType) {
                        continue
                    }
                    scheduled += 1
                    inFlight += 1
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
            }

            enqueueNext()
            diagnostics.queriedAddons = scheduled + diagnostics.skippedNeedsConfig

            var merged: [PlaybackCandidate] = []
            var seen = Set<String>()
            var seenURLs = Set<String>()
            while inFlight > 0 {
                if let batch = try await group.next() {
                    inFlight -= 1
                    diagnostics.playableHTTP += batch.stats.playable
                    diagnostics.skippedTorrent += batch.stats.torrent
                    diagnostics.skippedYouTube += batch.stats.youtube
                    diagnostics.skippedExternal += batch.stats.external
                    diagnostics.skippedUnsupportedFormat += batch.stats.unsupported
                    diagnostics.failedAddons += batch.stats.failed ? 1 : 0
                    if batch.usedTMDb { diagnostics.usedTMDbIdentifier = true }
                    for url in batch.stats.externalURLs.prefix(3) {
                        if diagnostics.sampleExternalURLs.count < 5 {
                            diagnostics.sampleExternalURLs.append(url)
                        }
                    }
                    for yt in batch.stats.youtubeIDs.prefix(3) {
                        if diagnostics.sampleYouTubeIDs.count < 5 {
                            diagnostics.sampleYouTubeIDs.append(yt)
                        }
                    }
                    progressRows.append(batch.progress)
                    StremioResolveDiagnosticsStore.publishProgress(progressRows)
                    for candidate in batch.candidates {
                        let normalized = Self.normalizedURLKey(from: candidate)
                        if let normalized, !seenURLs.insert(normalized).inserted {
                            continue
                        }
                        if seen.insert(candidate.id).inserted {
                            merged.append(candidate)
                        }
                    }
                    enqueueNext()
                } else {
                    break
                }
            }

            // One soft retry for hosts previously marked unreachable when primary wave was empty.
            if merged.isEmpty, !deferredAddons.isEmpty, !primaryAddons.isEmpty {
                iterator = deferredAddons.makeIterator()
                enqueueNext()
                while inFlight > 0 {
                    if let batch = try await group.next() {
                        inFlight -= 1
                        diagnostics.playableHTTP += batch.stats.playable
                        diagnostics.skippedTorrent += batch.stats.torrent
                        diagnostics.skippedYouTube += batch.stats.youtube
                        diagnostics.skippedExternal += batch.stats.external
                        diagnostics.skippedUnsupportedFormat += batch.stats.unsupported
                        diagnostics.failedAddons += batch.stats.failed ? 1 : 0
                        if batch.usedTMDb { diagnostics.usedTMDbIdentifier = true }
                        progressRows.append(batch.progress)
                        StremioResolveDiagnosticsStore.publishProgress(progressRows)
                        for candidate in batch.candidates {
                            let normalized = Self.normalizedURLKey(from: candidate)
                            if let normalized, !seenURLs.insert(normalized).inserted {
                                continue
                            }
                            if seen.insert(candidate.id).inserted {
                                merged.append(candidate)
                            }
                        }
                        enqueueNext()
                    } else {
                        break
                    }
                }
            }

            // Soft-rank: cached first, then binge continuity, already reflected in StreamSelectionPolicy.
            merged.sort { lhs, rhs in
                Self.previewRank(lhs, preferredBinge: preferredBinge)
                    .lexicographicallyPrecedes(Self.previewRank(rhs, preferredBinge: preferredBinge))
            }

            diagnostics.perAddon = progressRows
            StremioResolveDiagnosticsStore.update(diagnostics)
            if !merged.isEmpty {
                await StremioStreamSessionCache.shared.store(merged, for: cacheKey)
            }
            return merged
        }
    }

    private static func previewRank(_ candidate: PlaybackCandidate, preferredBinge: String?) -> [Int] {
        let meta = candidate.displayMetadata
        let cached = meta?.isDebridCached == true ? 0 : 1
        let binge: Int
        if let preferredBinge, !preferredBinge.isEmpty {
            binge = meta?.bingeGroup == preferredBinge ? 0 : 1
        } else {
            binge = 0
        }
        return [cached, binge]
    }

    private static func queryAddon(
        addon: (id: String, name: String, baseURL: URL, idPrefixes: [String]?, types: [String]?, requiresConfig: Bool, manifestURL: URL?, health: StremioAddonHealth),
        context: PlaybackLookupContext,
        mediaType: String,
        providerID: String,
        client: any HTTPClientProtocol,
        timeout: TimeInterval
    ) async -> (candidates: [PlaybackCandidate], stats: StreamBatchStats, usedTMDb: Bool, progress: StremioAddonResolveProgress) {
        var stats = StreamBatchStats()
        let started = Date()
        let usedTMDb: Bool
        do {
            let identifier = StremioAddonClient.streamIdentifier(
                for: context,
                idPrefixes: addon.idPrefixes
            )
            usedTMDb = identifier?.hasPrefix("tmdb:") == true
            guard let identifier else {
                let progress = StremioAddonResolveProgress(
                    addonID: addon.id,
                    addonName: addon.name,
                    status: .empty,
                    playable: 0,
                    skippedTorrent: 0,
                    latencyMS: Int(Date().timeIntervalSince(started) * 1000)
                )
                return ([], stats, false, progress)
            }
            if let prefixes = addon.idPrefixes, !prefixes.isEmpty {
                let ok = prefixes.contains {
                    identifier.hasPrefix($0) || (identifier.hasPrefix("tt") && $0.hasPrefix("tt"))
                }
                if !ok {
                    let progress = StremioAddonResolveProgress(
                        addonID: addon.id,
                        addonName: addon.name,
                        status: .empty,
                        playable: 0,
                        skippedTorrent: 0,
                        latencyMS: Int(Date().timeIntervalSince(started) * 1000)
                    )
                    return ([], stats, usedTMDb, progress)
                }
            }

            let addonClient = StremioAddonClient(client: client, baseURL: addon.baseURL)
            let streams: [StremioStream] = try await withTimeout(timeout) {
                try await addonClient.streams(type: mediaType, id: identifier)
            }

            var built: [PlaybackCandidate] = []
            let allowDirect = Self.directUnrestrictEnabled()
            let debridCreds = allowDirect ? Self.preferredDebridCredentials() : nil
            for (index, stream) in streams.enumerated() {
                switch stream.playbackKind {
                case .torrent:
                    stats.torrent += 1
                    if let hash = stream.infoHash,
                       let creds = debridCreds,
                       let candidate = await debridCandidate(
                        stream,
                        infoHash: hash,
                        order: index,
                        context: context,
                        addonID: addon.id,
                        addonName: addon.name,
                        providerID: providerID,
                        service: creds.service,
                        token: creds.token,
                        client: client
                       ) {
                        built.append(candidate)
                        stats.playable += 1
                    }
                case .youtube:
                    stats.youtube += 1
                    if let yt = stream.ytId { stats.youtubeIDs.append(yt) }
                case .external:
                    stats.external += 1
                    if let url = stream.externalUrl { stats.externalURLs.append(url) }
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
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let progress = StremioAddonResolveProgress(
                addonID: addon.id,
                addonName: addon.name,
                status: stats.playable > 0 ? .ok : (stats.failed ? .failed : .empty),
                playable: stats.playable,
                skippedTorrent: stats.torrent,
                latencyMS: ms
            )
            return (built, stats, usedTMDb, progress)
        } catch {
            stats.failed = true
            let progress = StremioAddonResolveProgress(
                addonID: addon.id,
                addonName: addon.name,
                status: .failed,
                playable: 0,
                skippedTorrent: 0,
                latencyMS: Int(Date().timeIntervalSince(started) * 1000)
            )
            return ([], stats, false, progress)
        }
    }

    private struct StreamBatchStats {
        var playable = 0
        var torrent = 0
        var youtube = 0
        var external = 0
        var unsupported = 0
        var failed = false
        var externalURLs: [URL] = []
        var youtubeIDs: [String] = []
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
        let bingeGroup = stream.behaviorHints?.bingeGroup
        let stableServer = [addonID, origin, quality, format, bingeGroup ?? "\(order)", filename ?? ""]
            .compactMap { $0 }
            .joined(separator: "|")
        let preference = PlaybackSourcePreference(
            providerID: providerID,
            serverName: stableServer,
            audioLanguage: language ?? ""
        )
        let candidateID = "\(providerID):\(stableServer.lowercased())"
        let cached = stream.looksDebridCached
        let labelOrigin = cached
            ? "\(origin) · \(addonName) · Cached"
            : "\(origin) · \(addonName)"
        let metadata = StreamDisplayMetadata(
            origin: labelOrigin,
            quality: quality,
            sizeBytes: stream.behaviorHints?.videoSize,
            container: format.uppercased(),
            audioLanguage: audio,
            releaseType: release,
            addonName: addonName,
            addonID: addonID,
            isDebridCached: cached,
            bingeGroup: bingeGroup,
            seedersHint: stream.seedersHint
        )
        let embeddedSubs = (stream.subtitles ?? []).compactMap { entry -> SubtitleSource? in
            guard let subURL = entry.url,
                  ["http", "https"].contains(subURL.scheme?.lowercased() ?? "") else { return nil }
            let lang = SubtitleLanguage.canonicalCode(entry.lang) ?? "und"
            return SubtitleSource(
                id: "\(providerID):embedded:\(addonID):\(subURL.absoluteString)",
                providerID: providerID,
                providerName: "\(addonName) (stream)",
                label: SubtitleLanguage.displayName(lang),
                languageCode: lang,
                url: subURL
            )
        }
        let initial = playbackSource(for: stream, url: url, embeddedSubtitles: embeddedSubs)
        let showID = context.request.media.id
        let resolver = RefreshingStremioSource(initial: initial) {
            let refreshed = try await client.streams(for: context)
            guard let match = refreshed.enumerated().first(where: { offset, candidate in
                stableServerKey(for: candidate, order: offset, addonID: addonID, addonName: addonName)
                    == stableServer
            }), let refreshedURL = match.element.url else {
                throw AppError.noStream
            }
            return playbackSource(for: match.element, url: refreshedURL, embeddedSubtitles: embeddedSubs)
        }
        return PlaybackCandidate(
            id: candidateID,
            preference: preference,
            providerName: labelOrigin,
            subtitleKind: embeddedSubs.isEmpty ? .unknown : .selectable,
            displayMetadata: metadata,
            resolve: {
                let source = try await resolver.resolve()
                if let bingeGroup {
                    StremioBingeContinuityStore.remember(
                        group: bingeGroup,
                        forShowID: showID,
                        addonID: addonID
                    )
                }
                return source
            }
        )
    }

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

    private static func playbackSource(
        for stream: StremioStream,
        url: URL,
        embeddedSubtitles: [SubtitleSource]
    ) -> PlaybackSource {
        PlaybackSource(
            url: url,
            headers: stream.behaviorHints?.proxyHeaders?.request ?? [:],
            subtitles: embeddedSubtitles,
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
        if candidate.id.contains(":torrent:") || candidate.id.contains(":external:") {
            return candidate.id
        }
        return candidate.id
            .components(separatedBy: "?")
            .first?
            .lowercased()
    }

    private static func debridCandidate(
        _ stream: StremioStream,
        infoHash: String,
        order: Int,
        context: PlaybackLookupContext,
        addonID: String,
        addonName: String,
        providerID: String,
        service: StremioDebridService,
        token: String,
        client: any HTTPClientProtocol
    ) async -> PlaybackCandidate? {
        let detail = stream.detailText
        let origin = cleanedName(stream.name)
            ?? cleanedName(stream.title)
            ?? "\(service.shortTitle) · \(addonName)"
        let quality = capture(#"(?i)(2160p|1080p|720p|480p|360p|4K)"#, in: detail)
            ?? capture(#"(?i)(2160p|1080p|720p|480p|360p|4K)"#, in: stream.displayLabel)
        let release = capture(#"(?i)\b(BluRay|WEB-DL|WEBRip|HDR|REMUX|HDTV|DVDRip)\b"#, in: detail)
        let filename = stream.behaviorHints?.filename
        let bingeGroup = stream.behaviorHints?.bingeGroup
        let fileIdx = stream.fileIdx
        let stableServer = [
            addonID,
            "debrid",
            service.rawValue,
            infoHash,
            fileIdx.map(String.init) ?? "\(order)",
            quality ?? "",
            bingeGroup ?? "",
            filename ?? "",
        ].joined(separator: "|")
        let preference = PlaybackSourcePreference(
            providerID: providerID,
            serverName: stableServer,
            audioLanguage: ""
        )
        let candidateID = "\(providerID):\(stableServer.lowercased())"
        let labelOrigin = "\(origin) · \(service.shortTitle)+ · \(addonName)"
        let metadata = StreamDisplayMetadata(
            origin: labelOrigin,
            quality: quality,
            sizeBytes: stream.behaviorHints?.videoSize,
            container: "HTTP",
            audioLanguage: nil,
            releaseType: release,
            addonName: addonName,
            addonID: addonID,
            isDebridCached: stream.looksDebridCached ? true : nil,
            bingeGroup: bingeGroup,
            seedersHint: stream.seedersHint
        )
        let showID = context.request.media.id
        return PlaybackCandidate(
            id: candidateID,
            preference: preference,
            providerName: labelOrigin,
            subtitleKind: .unknown,
            displayMetadata: metadata,
            resolve: {
                let url = try await StremioDebridMagnetResolver.resolveHTTPURL(
                    infoHash: infoHash,
                    fileIdx: fileIdx,
                    service: service,
                    token: token,
                    client: client
                )
                if let bingeGroup {
                    StremioBingeContinuityStore.remember(
                        group: bingeGroup,
                        forShowID: showID,
                        addonID: addonID
                    )
                }
                return PlaybackSource(url: url, headers: [:], subtitles: [], preferredPeakBitRate: nil)
            }
        )
    }

    private static func directUnrestrictEnabled() -> Bool {
        if UserDefaults.standard.object(forKey: StremioDebridStore.directUnrestrictKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: StremioDebridStore.directUnrestrictKey)
    }

    private static func preferredDebridCredentials() -> (service: StremioDebridService, token: String)? {
        let preferredRaw = UserDefaults.standard.string(forKey: StremioDebridStore.preferredServiceKey)
        let preferred = preferredRaw.flatMap(StremioDebridService.init(rawValue:)) ?? .realDebrid
        let order = [preferred] + StremioDebridService.allCases.filter { $0 != preferred }
        for service in order {
            if let token = loadToken(service: service), !token.isEmpty {
                return (service, token)
            }
        }
        return nil
    }

    private static func loadToken(service: StremioDebridService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.betterstreamflix.ios.stremio.debrid",
            kSecAttrAccount as String: "debrid.\(service.rawValue)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    private static func isDebridConfigured() -> Bool {
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
        let tmdbID = request.tmdbID
        return try await withThrowingTaskGroup(of: [SubtitleSource].self) { group in
            for addon in addons {
                group.addTask {
                    let client = StremioAddonClient(client: self.client, baseURL: addon.baseURL)
                    let entries = try await client.subtitles(
                        for: request,
                        idPrefixes: addon.idPrefixes,
                        tmdbID: tmdbID
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
