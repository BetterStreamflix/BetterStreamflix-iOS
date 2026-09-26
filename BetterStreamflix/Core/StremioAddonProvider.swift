import Foundation

struct StremioPlaybackProvider: PlaybackProvider {
    let id = "external-streams"
    private let client: any HTTPClientProtocol
    private let fixedAddons: [(id: String, name: String, baseURL: URL)]?

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        fixedAddons: [(id: String, name: String, baseURL: URL)]? = nil
    ) {
        self.client = client
        self.fixedAddons = fixedAddons
    }

    /// Backwards-compatible single-addon initializer used by unit tests.
    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL?) {
        self.client = client
        if let baseURL {
            fixedAddons = [("test", "Test", baseURL)]
        } else {
            fixedAddons = []
        }
    }

    func candidates(for context: PlaybackLookupContext) async throws -> [PlaybackCandidate] {
        let addons = fixedAddons ?? StremioAddonStore.snapshotStreamBaseURLs()
        guard !addons.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: [PlaybackCandidate].self) { group in
            for addon in addons {
                group.addTask {
                    let client = StremioAddonClient(client: self.client, baseURL: addon.baseURL)
                    let streams = try await client.streams(for: context)
                    return streams.enumerated().compactMap { index, stream in
                        Self.candidate(
                            stream,
                            order: index,
                            context: context,
                            addonID: addon.id,
                            addonName: addon.name,
                            client: client
                        )
                    }
                }
            }
            var merged: [PlaybackCandidate] = []
            var seen = Set<String>()
            for try await batch in group {
                for candidate in batch where seen.insert(candidate.id).inserted {
                    merged.append(candidate)
                }
            }
            return merged
        }
    }

    private static func candidate(
        _ stream: StremioStream,
        order: Int,
        context: PlaybackLookupContext,
        addonID: String,
        addonName: String,
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
        let stableServer = [addonID, origin, quality, format, stream.behaviorHints?.bingeGroup ?? "\(order)"]
            .compactMap { $0 }
            .joined(separator: "|")
        let preference = PlaybackSourcePreference(
            providerID: "external-streams",
            serverName: stableServer,
            audioLanguage: language ?? ""
        )
        let candidateID = "external-streams:\(stableServer.lowercased())"
        let metadata = StreamDisplayMetadata(
            origin: origin,
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
            providerName: origin,
            subtitleKind: .unknown,
            displayMetadata: metadata,
            resolve: { try await resolver.resolve() }
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
        return [addonID, origin, quality, format, stream.behaviorHints?.bingeGroup ?? "\(order)"]
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
        // Many CDN streams omit extensions; accept as progressive MP4 when not clearly incompatible.
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
    private let fixedAddons: [(id: String, name: String, baseURL: URL)]?

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        fixedAddons: [(id: String, name: String, baseURL: URL)]? = nil
    ) {
        self.client = client
        self.fixedAddons = fixedAddons
    }

    init(client: any HTTPClientProtocol = HTTPClient(), baseURL: URL?) {
        self.client = client
        if let baseURL {
            fixedAddons = [("test", "External", baseURL)]
        } else {
            fixedAddons = []
        }
    }

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        let addons = fixedAddons ?? StremioAddonStore.snapshotSubtitleBaseURLs()
        guard !addons.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: [SubtitleSource].self) { group in
            for addon in addons {
                group.addTask {
                    let client = StremioAddonClient(client: self.client, baseURL: addon.baseURL)
                    let entries = try await client.subtitles(for: request)
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
