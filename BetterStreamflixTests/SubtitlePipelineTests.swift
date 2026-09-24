import Foundation
import Testing
@testable import BetterStreamflix

@Suite("Subtitle performance pipeline", .serialized)
struct SubtitlePipelineTests {
    @Test("Cache identity survives signed URL changes and second playback avoids a download")
    func stableSignedURLCacheKey() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SubtitleRenditionCache(directory: directory)
        let counter = CueLoadCounter()
        let first = subtitle(url: "https://cdn.example/release.srt?token=one")
        let second = subtitle(url: "https://cdn.example/release.srt?token=two")

        _ = try await cache.rendition(contentID: "episode-1", subtitle: first) {
            await counter.load()
        }
        let cached = try await cache.rendition(contentID: "episode-1", subtitle: second) {
            await counter.load()
        }

        #expect(await counter.count == 1)
        #expect(cached.cues.first?.text == "Cached cue")
        #expect(cached.subtitle.syncKey == first.syncKey)
    }

    @Test("Cache isolates movies and episodes")
    func contentIsolation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SubtitleRenditionCache(directory: directory)
        let counter = CueLoadCounter()
        let source = subtitle(url: "https://cdn.example/release.srt")

        _ = try await cache.rendition(contentID: "episode-1", subtitle: source) {
            await counter.load()
        }
        _ = try await cache.rendition(contentID: "episode-2", subtitle: source) {
            await counter.load()
        }

        #expect(await counter.count == 2)
    }

    @Test("Source subtitles retain identity across signatures but stay source-specific")
    func sourceSubtitleIdentity() throws {
        func source(video: String, track: String) throws -> PlaybackSource {
            let json = #"{"sources":[{"file":"\#(video)"}],"tracks":[{"file":"\#(track)","label":"Hebrew","srclang":"he"}]}"#
            return try AnimeStreamResolver.source(
                from: Data(json.utf8),
                relativeTo: URL(string: "https://media.example/")!,
                headers: [:]
            )
        }
        let first = try source(
            video: "https://media.example/source-a.m3u8?token=one",
            track: "https://media.example/a-he.vtt?token=one"
        )
        let refreshed = try source(
            video: "https://media.example/source-a.m3u8?token=two",
            track: "https://media.example/a-he.vtt?token=two"
        )
        let other = try source(
            video: "https://media.example/source-b.m3u8?token=one",
            track: "https://media.example/b-he.vtt?token=one"
        )
        #expect(first.subtitles.first?.syncKey == refreshed.subtitles.first?.syncKey)
        #expect(first.subtitles.first?.syncKey != other.subtitles.first?.syncKey)
    }

    @Test("Concurrent requests for one subtitle are coalesced")
    func requestCoalescing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SubtitleRenditionCache(directory: directory)
        let loader = ControlledCueLoader()
        let source = subtitle(url: "https://cdn.example/coalesced.srt")

        async let first = cache.rendition(contentID: "episode", subtitle: source) {
            await loader.load()
        }
        async let second = cache.rendition(contentID: "episode", subtitle: source) {
            await loader.load()
        }
        await loader.waitUntilStarted()
        await loader.release()
        _ = try await (first, second)

        #expect(await loader.count == 1)
    }

    @Test("Corrupt cache entries self-evict")
    func corruptCacheEviction() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = subtitle(url: "https://cdn.example/corrupt.srt")
        let cache = SubtitleRenditionCache(directory: directory)
        await cache.store(
            rendition: HLSSubtitleRendition(
                subtitle: source,
                cues: [SubtitleCue(startTime: 1, endTime: 2, text: "Valid")]
            ),
            contentID: "episode"
        )
        let corrupt = try #require(cacheFiles(in: directory).first)
        try Data("not-json".utf8).write(to: corrupt)
        let reader = SubtitleRenditionCache(directory: directory)

        #expect(await reader.cachedRenditions(for: "episode").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
    }

    @Test("Stale cache is returned immediately while one refresh runs in the background")
    func staleFallbackAndRefresh() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SubtitleRenditionCache(directory: directory, freshInterval: -1)
        let source = subtitle(url: "https://cdn.example/stale.srt")
        await cache.store(
            rendition: HLSSubtitleRendition(
                subtitle: source,
                cues: [SubtitleCue(startTime: 1, endTime: 2, text: "Stale cue")]
            ),
            contentID: "episode"
        )
        let loader = ControlledCueLoader()

        let stale = try await cache.rendition(contentID: "episode", subtitle: source) {
            await loader.load()
        }

        #expect(stale.cues.first?.text == "Stale cue")
        await loader.waitUntilStarted()
        #expect(await loader.count == 1)
        await loader.release()
        for _ in 0..<100 {
            if await cache.lookup(contentID: "episode", subtitle: source)?.rendition.cues.first?.text
                == "Coalesced" {
                return
            }
            await Task.yield()
        }
        Issue.record("Expected the stale cache refresh to complete")
    }

    @Test("Incompatible cache schema self-evicts")
    func schemaEviction() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = subtitle(url: "https://cdn.example/schema.srt")
        let writer = SubtitleRenditionCache(directory: directory)
        await writer.store(
            rendition: HLSSubtitleRendition(
                subtitle: source,
                cues: [SubtitleCue(startTime: 1, endTime: 2, text: "Old schema")]
            ),
            contentID: "episode"
        )
        let file = try #require(cacheFiles(in: directory).first)
        var json = try String(contentsOf: file, encoding: .utf8)
        json = json.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":999"#)
        try Data(json.utf8).write(to: file, options: .atomic)

        let reader = SubtitleRenditionCache(directory: directory)
        #expect(await reader.cachedRenditions(for: "episode").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("LRU pruning enforces the configured global size cap")
    func sizePruning() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = SubtitleRenditionCache(directory: directory, sizeLimit: 1)
        let source = subtitle(url: "https://cdn.example/large.srt")
        await cache.store(
            rendition: HLSSubtitleRendition(
                subtitle: source,
                cues: [SubtitleCue(startTime: 0, endTime: 2, text: String(repeating: "x", count: 2_000))]
            ),
            contentID: "episode"
        )

        #expect(await cache.cachedRenditions(for: "episode").isEmpty)
    }

    @Test("Progressive provider results do not wait for a stalled provider")
    func progressiveProviderResults() async throws {
        let gate = ProviderGate()
        let fastSource = subtitle(url: "https://cdn.example/fast.srt")
        let registry = SubtitleProviderRegistry(providers: [
            ImmediateSubtitleProvider(source: fastSource),
            GatedSubtitleProvider(gate: gate),
        ])
        let stream = await registry.progressiveResults(
            for: SubtitleLookupRequest(
                kind: .movie,
                imdbID: "tt1234567",
                seasonNumber: nil,
                episodeNumber: nil
            ),
            enabledProviderIDs: ["immediate", "gated"]
        )
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()

        #expect(first?.providerID == "immediate")
        #expect(first?.subtitles == [fastSource])
        await gate.release()
        _ = await iterator.next()
    }

    @Test("Corrected IMDb results arrive while the original lookup is stalled")
    func correctedIMDbFallbackIsProgressive() async throws {
        let gate = ProviderGate()
        let corrected = subtitle(url: "https://cdn.example/corrected.srt")
        let registry = SubtitleProviderRegistry(
            providers: [CorrectedIMDbSubtitleProvider(gate: gate, source: corrected)],
            imdbIDResolver: ImmediateIMDbResolver()
        )
        let stream = await registry.progressiveResults(
            for: SubtitleLookupRequest(
                kind: .movie,
                imdbID: "tt0000001",
                seasonNumber: nil,
                episodeNumber: nil
            ),
            fallbackTMDbID: 123,
            enabledProviderIDs: ["corrected-imdb"]
        )
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.usedCorrectedIMDbID == true)
        #expect(first?.subtitles == [corrected])
        await gate.release()
        _ = await iterator.next()
    }

    @Test("Native descriptor discovery does not fetch subtitle media")
    func nativeMetadataOnlyStartup() async throws {
        let client = NativeSubtitleHTTPClient()
        let source = PlaybackSource(
            url: URL(string: "https://video.example/master.m3u8")!,
            headers: [:],
            subtitles: [],
            preferredPeakBitRate: nil
        )

        let descriptors = await HLSNativeSubtitleLoader.descriptors(from: source, client: client)
        #expect(descriptors.count == 1)
        #expect(await client.paths == ["/master.m3u8"])

        let rendition = await HLSNativeSubtitleLoader.load(
            descriptor: try #require(descriptors.first),
            from: source,
            client: client
        )
        #expect(rendition?.cues.count == 1)
        #expect(await client.paths.contains("/subtitle.m3u8"))
        #expect(await client.paths.contains("/subtitle-0.vtt"))
    }

    @Test("Direct MP4 is never downloaded as a playlist")
    func directMovieSkipsPlaylistFetch() async {
        let client = CountingHTTPClient()
        let source = PlaybackSource(
            url: URL(string: "https://video.example/movie.mp4?signature=temporary")!,
            headers: [:],
            subtitles: [],
            preferredPeakBitRate: nil
        )
        let rendition = HLSSubtitleRendition(
            subtitle: subtitle(url: "https://cdn.example/direct.srt"),
            cues: [SubtitleCue(startTime: 1, endTime: 2, text: "Cue")]
        )
        do {
            _ = try await HLSSubtitleInjector.prepare(
                source: source,
                renditions: [rendition],
                client: client
            )
            Issue.record("An ordinary MP4 cannot be used as an HLS playlist")
        } catch {
            #expect(await client.requestCount == 0)
        }
    }

    @MainActor
    @Test("Remembered subtitle survives subtitles being turned off and reloads per episode")
    func rememberedSelectionPersistence() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = PlaybackDiscoveryTests.request
        let source = subtitle(url: "https://cdn.example/remembered.srt")
        let preference = SubtitleSelectionPreference(
            baseSubtitleKey: source.syncKey,
            syncVersionID: UUID()
        )
        let library = LibraryStore(directory: directory)
        library.updateSubtitleSelectionPreference(preference, for: request)
        library.updateSubtitleVisibilityPreference(false, for: request)

        let reloaded = LibraryStore(directory: directory)
        #expect(reloaded.subtitleSelectionPreference(for: request) == preference)
        #expect(reloaded.subtitleVisibilityPreference(for: request) == false)
    }

    @Test("A missing first subtitle track is not an explicit Off choice")
    func pendingPreferredSubtitleKeepsVisibilityIntent() {
        var observation = SubtitleVisibilityObservation()
        observation.beginPlayerItem()

        let initialEmptySelection = observation.shouldPersistSelection(
            isSelected: false,
            subtitlesRequestedOn: true
        )
        let activatedSelection = observation.shouldPersistSelection(
            isSelected: true,
            subtitlesRequestedOn: true
        )
        let explicitOffAfterSelection = observation.shouldPersistSelection(
            isSelected: false,
            subtitlesRequestedOn: true
        )
        #expect(!initialEmptySelection)
        #expect(activatedSelection)
        #expect(explicitOffAfterSelection)

        observation.beginPlayerItem()
        let alreadyOff = observation.shouldPersistSelection(
            isSelected: false,
            subtitlesRequestedOn: false
        )
        #expect(alreadyOff)
    }

    @MainActor
    @Test("Backup includes remembered selection while cue cache stays outside the archive")
    func backupBoundary() throws {
        let support = temporaryDirectory()
        let restoredSupport = temporaryDirectory()
        let cacheDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: support)
            try? FileManager.default.removeItem(at: restoredSupport)
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try Data("cache-only-marker".utf8).write(
            to: cacheDirectory.appending(path: "cue-cache.bin")
        )
        let request = PlaybackDiscoveryTests.request
        let preference = SubtitleSelectionPreference(
            baseSubtitleKey: subtitle(url: "https://cdn.example/backup.srt").syncKey,
            syncVersionID: nil
        )
        let library = LibraryStore(directory: support)
        library.updateSubtitleSelectionPreference(preference, for: request)
        let backup = try library.exportUserData()
        let backupText = String(decoding: backup, as: UTF8.self)

        #expect(backupText.contains("subtitle-selection-preferences.json"))
        #expect(!backupText.contains("cache-only-marker"))

        let restored = LibraryStore(directory: restoredSupport)
        try restored.importUserData(backup)
        #expect(restored.subtitleSelectionPreference(for: request) == preference)
    }

    private func subtitle(url: String) -> SubtitleSource {
        SubtitleSource(
            id: "stable-release",
            providerID: "wizdom",
            providerName: "Wizdom",
            label: "Release.1080p",
            languageCode: "he",
            url: URL(string: url)!
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "subtitle-pipeline-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    private func cacheFiles(in directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "json" }
    }
}

private actor CueLoadCounter {
    private(set) var count = 0

    func load() -> [SubtitleCue] {
        count += 1
        return [SubtitleCue(startTime: 1, endTime: 2, text: "Cached cue")]
    }
}

private actor ControlledCueLoader {
    private(set) var count = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func load() async -> [SubtitleCue] {
        count += 1
        await withCheckedContinuation { continuation = $0 }
        return [SubtitleCue(startTime: 1, endTime: 2, text: "Coalesced")]
    }

    func waitUntilStarted() async {
        while count == 0 { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ProviderGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private struct ImmediateSubtitleProvider: SubtitleProvider {
    let id = "immediate"
    let displayName = "Immediate"
    let source: SubtitleSource

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] { [source] }
}

private struct GatedSubtitleProvider: SubtitleProvider {
    let id = "gated"
    let displayName = "Gated"
    let gate: ProviderGate

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        await gate.wait()
        return []
    }
}

private struct CorrectedIMDbSubtitleProvider: SubtitleProvider {
    let id = "corrected-imdb"
    let displayName = "Corrected IMDb"
    let gate: ProviderGate
    let source: SubtitleSource

    func subtitles(for request: SubtitleLookupRequest) async throws -> [SubtitleSource] {
        if request.imdbID == "tt7654321" { return [source] }
        await gate.wait()
        return []
    }
}

private struct ImmediateIMDbResolver: IMDbIDResolving {
    func imdbID(forTMDbID tmdbID: Int, kind: MediaKind) async throws -> String? {
        "tt7654321"
    }
}

private actor NativeSubtitleHTTPClient: HTTPClientProtocol {
    private(set) var paths: [String] = []

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        paths.append(url.path)
        let body: String
        switch url.path {
        case "/master.m3u8":
            body = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="Hebrew",LANGUAGE="he",DEFAULT=YES,AUTOSELECT=YES,URI="subtitle.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000000,SUBTITLES="subs"
            video.m3u8
            """
        case "/subtitle.m3u8":
            body = """
            #EXTM3U
            #EXT-X-TARGETDURATION:10
            #EXTINF:10,
            subtitle-0.vtt
            #EXT-X-ENDLIST
            """
        case "/subtitle-0.vtt":
            body = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nשלום\n"
        default:
            throw AppError.invalidResponse
        }
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: nil
        ))
        return HTTPResponse(data: Data(body.utf8), response: response)
    }
}

private actor CountingHTTPClient: HTTPClientProtocol {
    private(set) var requestCount = 0

    func data(for request: URLRequest) async throws -> HTTPResponse {
        requestCount += 1
        throw AppError.invalidResponse
    }
}
