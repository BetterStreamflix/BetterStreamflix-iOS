import Foundation
import Testing
@testable import BetterStreamflix

@Suite("Stremio addon protocol & playback")
struct StremioAddonProviderTests {
    private let baseURL = URL(string: "https://addon.example/config")!

    @Test("Movie streams keep playable formats, metadata, and proxy headers")
    func movieStreams() async throws {
        let client = StremioFixtureClient(streamBody: #"""
        {
          "streams": [
            {"name":"support", "description":"donate"},
            {"name":"Provider", "description":"🎞️ 4K • MKV • HDR\n🛰️ Source: 4KHDHub", "url":"https://cdn.example/movie.mkv"},
            {"name":"Provider", "description":"🎞️ 1080p • MP4 • BluRay\n🛰️ Source: 2Peckle\n💾 4 GB\n🎧 Audio: English", "url":"https://cdn.example/movie.mp4?token=one",
             "behaviorHints":{"videoSize":4294967296,"bingeGroup":"twopeckle-1080-1","filename":"original.mkv1080pMP4.pad-2Peckle","proxyHeaders":{"request":{"Referer":"https://upstream.example/"}}}},
            {"name":"Provider", "description":"🎞️ 720p • HLS\n🛰️ Source: Cinejoy · Lisbon", "url":"https://cdn.example/master.m3u8"},
            {"name":"torrent", "description":"🎞️ 1080p • MP4\n🛰️ Source: Torrent", "infoHash":"abc"}
          ]
        }
        """#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        let movie = MediaItem(id: "movie", providerID: "tmdb", kind: .movie,
                              title: "Example", imdbID: "tt0133093")
        let candidates = try await provider.candidates(for: .init(request: .init(media: movie, episode: nil)))

        #expect(client.requestedPaths == ["/config/stream/movie/tt0133093.json"])
        #expect(candidates.count == 2)
        let direct = try #require(candidates.first { $0.providerName.contains("2Peckle") })
        #expect(direct.preference.audioLanguage == "en")
        #expect(direct.displayMetadata?.quality == "1080p")
        #expect(direct.displayMetadata?.sizeBytes == 4_294_967_296)
        #expect(!direct.id.lowercased().contains("pengu"))
        let source = try await direct.resolve()
        #expect(source.headers["Referer"] == "https://upstream.example/")
        let refreshed = try await direct.resolve()
        #expect(refreshed.url == source.url)
        #expect(client.requestedPaths.count == 2)
        let stream = PlayableStream(candidate: direct, source: source, qualities: [])
        #expect(stream.label.contains("2Peckle"))
        #expect(stream.label.contains("1080p"))
        #expect(!stream.label.lowercased().contains("pengu"))
        let diag = StremioResolveDiagnosticsStore.current()
        #expect(diag.skippedTorrent >= 1)
    }

    @Test("Series routes use the Stremio season and episode identifier")
    func seriesRoute() async throws {
        let client = StremioFixtureClient(streamBody: #"{"streams":[]}"#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        let show = MediaItem(id: "show", providerID: "tmdb", kind: .series,
                             title: "Show", imdbID: "tt0944947")
        let episode = MediaEpisode(id: "episode", providerID: "tmdb", showID: "show",
                                   seasonNumber: 2, number: 3, title: nil, overview: nil, posterURL: nil)
        _ = try await provider.candidates(for: .init(request: .init(media: show, episode: episode)))
        #expect(client.requestedPaths == ["/config/stream/series/tt0944947:2:3.json"])
    }

    @Test("TMDb identifiers are used when IMDb is missing")
    func tmdbIdentifierRouting() async throws {
        let client = StremioFixtureClient(streamBody: #"{"streams":[]}"#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        let movie = MediaItem(
            id: "movie",
            providerID: "tmdb",
            kind: .movie,
            title: "Example",
            tmdbID: 603
        )
        _ = try await provider.candidates(for: .init(request: .init(media: movie, episode: nil)))
        #expect(client.requestedPaths == ["/config/stream/movie/tmdb:603.json"])
    }

    @Test("Stremio subtitles have stable identities, canonical languages, and provider labels")
    func subtitles() async throws {
        let body = #"""
        {"subtitles":[
          {"id":"moviebox-123","lang":"eng","url":"https://subs.example/en.srt?Policy=first"},
          {"id":"https://proxy.example/sub/456","lang":"deu","url":"https://subs.example/de.srt?token=second"},
          {"id":"bad","lang":"eng","url":"file:///tmp/subtitle.srt"}
        ]}
        """#
        let client = StremioFixtureClient(subtitleBody: body)
        let provider = StremioSubtitleProvider(client: client, baseURL: baseURL)
        let request = SubtitleLookupRequest(kind: .series, imdbID: "tt0944947",
                                            seasonNumber: 1, episodeNumber: 2)
        let subtitles = try await provider.subtitles(for: request)

        #expect(client.requestedPaths == ["/config/subtitles/series/tt0944947:1:2.json"])
        #expect(subtitles.count == 2)
        #expect(subtitles.first?.providerName == "MovieBox")
        #expect(subtitles.first?.languageCode == "en")
        #expect(subtitles.first?.userFacingDisplayName == "English - MovieBox - English")
        #expect(subtitles.last?.providerName == "Stremio")
        #expect(subtitles.last?.languageCode == "de")
        #expect(subtitles.last?.userFacingDisplayName == "German - Stremio - German")
        #expect(subtitles.allSatisfy { !$0.id.contains("Policy=") && !$0.id.contains("token=") })
    }

    @Test("Missing and malformed IMDb identifiers without TMDb make no request")
    func missingIdentifier() async throws {
        let client = StremioFixtureClient(streamBody: #"{"streams":[]}"#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        for imdbID in [nil, "12345", "tt12"] {
            let movie = MediaItem(id: "movie", providerID: "tmdb", kind: .movie,
                                  title: "Example", imdbID: imdbID)
            #expect(try await provider.candidates(for: .init(request: .init(media: movie, episode: nil))).isEmpty)
        }
        #expect(client.requestedPaths.isEmpty)
    }

    @Test("General addon streams without Source lines still resolve")
    func generalAddonStreams() async throws {
        let client = StremioFixtureClient(streamBody: #"""
        {"streams":[
          {"name":"CDN 1080p","title":"Fast mirror","url":"https://cdn.example/title.mp4"},
          {"name":"Torrent only","infoHash":"deadbeef"}
        ]}
        """#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        let movie = MediaItem(id: "movie", providerID: "tmdb", kind: .movie,
                              title: "Example", imdbID: "tt0133093")
        let candidates = try await provider.candidates(for: .init(request: .init(media: movie, episode: nil)))
        #expect(candidates.count == 1)
        #expect(candidates.first?.providerName.contains("CDN 1080p") == true)
        #expect(StremioResolveDiagnosticsStore.current().skippedTorrent >= 1)
    }

    @Test("Multi-addon playback merges stream candidates")
    func multiAddonMerge() async throws {
        let client = StremioFixtureClient(streamBody: #"""
        {"streams":[{"name":"A","url":"https://cdn.example/a.mp4"}]}
        """#)
        let first = URL(string: "https://one.example/config")!
        let second = URL(string: "https://two.example/config")!
        let provider = StremioPlaybackProvider(
            client: client,
            fixedAddons: [
                ("one", "One", first),
                ("two", "Two", second),
            ]
        )
        let movie = MediaItem(id: "movie", providerID: "tmdb", kind: .movie,
                              title: "Example", imdbID: "tt0133093")
        let candidates = try await provider.candidates(for: .init(request: .init(media: movie, episode: nil)))
        #expect(candidates.count == 2)
        #expect(Set(client.requestedPaths) == [
            "/config/stream/movie/tt0133093.json",
        ])
        #expect(client.requestedPaths.count == 2)
    }

    @Test("Manifest URL parsing accepts stremio deep links and noisy paste")
    func manifestURLParsing() {
        let https = StremioManifestURL.parse("https://v3-cinemeta.strem.io/manifest.json")
        #expect(https?.absoluteString == "https://v3-cinemeta.strem.io/manifest.json")
        let deep = StremioManifestURL.parse("stremio://opensubtitles-v3.strem.io/manifest.json")
        #expect(deep?.scheme == "https")
        let bare = StremioManifestURL.parse("opensubtitles-v3.strem.io")
        #expect(bare?.lastPathComponent == "manifest.json")
        let noisy = StremioManifestURL.parse("Install this: https://v3-cinemeta.strem.io/manifest.json thanks!")
        #expect(noisy?.host == "v3-cinemeta.strem.io")
        let quoted = StremioManifestURL.parse("\"https://torrentio.strem.fun/manifest.json\"")
        #expect(quoted?.host == "torrentio.strem.fun")
    }

    @Test("Bundled Pengu hosts are banned from the community plugin list")
    func bansBundledPengu() {
        let url = URL(string: "https://pengu.uk/%7B%22auth_token%22%3A%22x%22%7D/manifest.json")!
        #expect(StremioCuratedCatalog.isBannedPlugin(url: url, manifestID: "com.penguplay"))
        #expect(!StremioCuratedCatalog.isBannedPlugin(
            url: URL(string: "https://v3-cinemeta.strem.io/manifest.json")!,
            manifestID: "com.linvo.cinemeta"
        ))
        #expect(StremioCuratedCatalog.seedDefaults.allSatisfy {
            !StremioCuratedCatalog.isBannedPlugin(url: $0.manifestURL, manifestID: $0.id)
        })
    }

    @Test("Catalog meta previews map into MediaItem with IMDb identity")
    func catalogMetaMapping() throws {
        let json = Data(#"""
        {"metas":[{"id":"tt0133093","type":"movie","name":"The Matrix",
          "poster":"https://img.example/p.jpg","imdb_id":"tt0133093","imdbRating":"8.7"}]}
        """#.utf8)
        let payload = try JSONDecoder().decode(StremioCatalogPayload.self, from: json)
        let item = try #require(payload.metas.first).asMediaItem(providerID: "stremio:cinemeta")
        #expect(item.imdbID == "tt0133093")
        #expect(item.kind == .movie)
        #expect(item.title == "The Matrix")
        #expect(item.posterURL?.absoluteString == "https://img.example/p.jpg")
    }

    @Test("Catalog requests encode search extras on the Stremio path")
    func catalogSearchPath() async throws {
        let client = StremioFixtureClient(catalogBody: #"{"metas":[]}"#)
        let addon = StremioAddonClient(client: client, baseURL: baseURL)
        _ = try await addon.catalog(type: "movie", id: "top", extras: ["search": "matrix"])
        #expect(client.requestedPaths == ["/config/catalog/movie/top/search=matrix.json"])
    }

    @Test("Catalog pagination encodes skip extras")
    func catalogSkipPagination() async throws {
        let client = StremioFixtureClient(catalogBody: #"{"metas":[]}"#)
        let addon = StremioAddonClient(client: client, baseURL: baseURL)
        _ = try await addon.catalog(type: "movie", id: "top", extras: ["skip": "40"])
        #expect(client.requestedPaths == ["/config/catalog/movie/top/skip=40.json"])
    }

    @Test("Debrid URL builder injects Real-Debrid into Torrentio manifests")
    func debridURLBuilder() {
        let base = URL(string: "https://torrentio.strem.fun/manifest.json")!
        let url = StremioDebridURLBuilder.configuredManifestURL(
            for: "com.stremio.torrentio.addon",
            service: .realDebrid,
            token: "TOKEN123",
            baseManifestURL: base
        )
        #expect(url?.absoluteString.contains("realdebrid=TOKEN123") == true)
        #expect(url?.lastPathComponent == "manifest.json")
        #expect(StremioDebridURLBuilder.looksConfigured(url!))
        #expect(!StremioDebridURLBuilder.looksConfigured(base))
    }

    @Test("Configure page strips Debrid path segments back to origin")
    func configurePageUsesBareOrigin() {
        let configured = URL(string: "https://torrentio.strem.fun/realdebrid=TOKEN|cached=true/manifest.json")!
        let page = StremioDebridURLBuilder.configurePageURL(from: configured)
        #expect(page.absoluteString == "https://torrentio.strem.fun/configure")
        #expect(InstalledStremioAddon(
            id: "t",
            manifestURL: configured,
            baseURL: configured.deletingLastPathComponent(),
            name: "Torrentio",
            isEnabled: true,
            sortOrder: 0,
            supportsCatalog: false,
            supportsMeta: false,
            supportsStream: true,
            supportsSubtitles: false,
            catalogs: [],
            health: .unknown,
            isCurated: true,
            isConfigurable: true,
            requiresConfiguration: true
        ).configurePageURL?.absoluteString == "https://torrentio.strem.fun/configure")
    }

    @Test("Comet opaque config segments count as configured")
    func cometLooksConfigured() {
        let b64 = String(repeating: "A", count: 40)
        let configured = URL(string: "https://comet.elfhosted.com/\(b64)/manifest.json")!
        #expect(StremioDebridURLBuilder.looksConfigured(configured))
        let bare = StremioDebridURLBuilder.bareManifestURL(from: configured)
        #expect(bare.absoluteString == "https://comet.elfhosted.com/manifest.json")
    }

    @Test("stremio:///https:// paste form parses to https host")
    func stremioEmbeddedHTTPS() {
        let parsed = StremioManifestURL.parse("stremio:///https://torrentio.strem.fun/realdebrid=T/manifest.json")
        #expect(parsed?.host == "torrentio.strem.fun")
        #expect(parsed?.path.contains("manifest.json") == true)
        let configure = StremioManifestURL.parse("https://torrentio.strem.fun/configure")
        #expect(configure?.lastPathComponent == "configure")
        #expect(configure?.path.hasSuffix("/configure/manifest.json") != true)
    }

    @Test("MediaFusion one-tap Debrid returns nil so Configure is used")
    func mediaFusionNeedsConfigure() {
        let base = URL(string: "https://mediafusion.elfhosted.com/manifest.json")!
        let url = StremioDebridURLBuilder.configuredManifestURL(
            for: "mediafusion",
            service: .realDebrid,
            token: "TOKEN",
            baseManifestURL: base
        )
        #expect(url == nil)
    }

    @Test("TorBox builder requires TorBox service token")
    func torboxRequiresTorBoxToken() {
        let base = URL(string: "https://stremio.torbox.app/manifest.json")!
        let wrong = StremioDebridURLBuilder.configuredManifestURL(
            for: "com.torbox.stremio",
            service: .realDebrid,
            token: "RDTOKEN",
            baseManifestURL: base
        )
        #expect(wrong == nil)
        let ok = StremioDebridURLBuilder.configuredManifestURL(
            for: "com.torbox.stremio",
            service: .torbox,
            token: "TBKEY",
            baseManifestURL: base
        )
        #expect(ok?.absoluteString == "https://stremio.torbox.app/TBKEY/manifest.json")
    }

    @Test("Deep link install queues betterstreamflix and stremio URLs")
    func deepLinkInstall() {
        let stremio = URL(string: "stremio://v3-cinemeta.strem.io/manifest.json")!
        #expect(StremioInstallDeepLink.handle(url: stremio))
        #expect(StremioInstallDeepLink.consumePending()?.contains("v3-cinemeta.strem.io") == true)

        let app = URL(string: "betterstreamflix://install?url=https%3A%2F%2Fopensubtitles-v3.strem.io%2Fmanifest.json")!
        #expect(StremioInstallDeepLink.handle(url: app))
        #expect(StremioInstallDeepLink.consumePending()?.contains("opensubtitles-v3") == true)
    }

    @Test("Resolve diagnostics explain torrent-only empty states")
    func diagnosticsCopy() {
        var diag = StremioResolveDiagnostics()
        diag.queriedAddons = 2
        diag.skippedTorrent = 12
        diag.debridConfigured = false
        #expect(diag.userFacingSummary.lowercased().contains("debrid"))
        #expect(diag.userFacingSummary.lowercased().contains("torrent"))
    }

    @Test("Manifest behaviorHints decode configurable and adult flags")
    func behaviorHintsDecode() throws {
        let json = Data(#"""
        {"id":"x","name":"X","resources":["stream"],"types":["movie"],
         "behaviorHints":{"adult":true,"p2p":true,"configurable":true,"configurationRequired":true},
         "catalogs":[]}
        """#.utf8)
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: json)
        #expect(manifest.isAdult)
        #expect(manifest.isP2P)
        #expect(manifest.isConfigurable)
        #expect(manifest.requiresConfiguration)
        #expect(manifest.accepts(resource: "stream", type: "movie", id: "tt0133093"))
    }

    @Test("Resource idPrefixes gate unsupported identifiers")
    func resourceIdPrefixGuard() throws {
        let json = Data(#"""
        {"id":"x","name":"X","resources":[{"name":"stream","types":["movie"],"idPrefixes":["tt"]}],
         "types":["movie"],"catalogs":[]}
        """#.utf8)
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: json)
        #expect(manifest.accepts(resource: "stream", type: "movie", id: "tt0133093"))
        #expect(!manifest.accepts(resource: "stream", type: "series", id: "tt0133093"))
        #expect(!manifest.accepts(resource: "stream", type: "movie", id: "tmdb:603"))
    }

    @Test("TorBox official addon builds key-in-path manifest URL")
    func torboxInstallURL() {
        let base = URL(string: "https://stremio.torbox.app/manifest.json")!
        let url = StremioDebridURLBuilder.configuredManifestURL(
            for: "com.torbox.stremio",
            service: .torbox,
            token: "TBKEY",
            baseManifestURL: base
        )
        #expect(url?.absoluteString == "https://stremio.torbox.app/TBKEY/manifest.json")
        #expect(StremioCuratedCatalog.popularPresets.contains {
            StremioCuratedCatalog.isDebridStreamPreset($0) && $0.name == "TorBox"
        })
        #expect(StremioDebridURLBuilder.looksConfigured(
            URL(string: "https://stremio.torbox.app/TBKEY/manifest.json")!
        ))
    }

    @Test("Stream selection prefers healthy seeders and avoids CAM")
    func seederAndReleaseRanking() {
        let cam = PlayableStream(
            candidate: PlaybackCandidate(
                id: "cam",
                preference: .init(providerID: "external-streams", serverName: "cam", audioLanguage: "en"),
                providerName: "CAM",
                subtitleKind: .unknown,
                displayMetadata: StreamDisplayMetadata(origin: "CAM", releaseType: "CAM", seedersHint: 2),
                resolve: { PlaybackSource(url: URL(string: "https://a.example/cam.mp4")!, headers: [:], subtitles: [], preferredPeakBitRate: nil) }
            ),
            source: PlaybackSource(url: URL(string: "https://a.example/cam.mp4")!, headers: [:], subtitles: [], preferredPeakBitRate: nil),
            qualities: []
        )
        let web = PlayableStream(
            candidate: PlaybackCandidate(
                id: "web",
                preference: .init(providerID: "external-streams", serverName: "web", audioLanguage: "en"),
                providerName: "WEB",
                subtitleKind: .unknown,
                displayMetadata: StreamDisplayMetadata(origin: "WEB", releaseType: "WEB-DL", seedersHint: 80),
                resolve: { PlaybackSource(url: URL(string: "https://a.example/web.mp4")!, headers: [:], subtitles: [], preferredPeakBitRate: nil) }
            ),
            source: PlaybackSource(url: URL(string: "https://a.example/web.mp4")!, headers: [:], subtitles: [], preferredPeakBitRate: nil),
            qualities: []
        )
        var policy = StreamSelectionPolicy()
        policy.preferHealthySeeders = true
        #expect(policy.best(in: [cam, web])?.id == "web")
    }

    @Test("Debrid stream presets are flagged for one-tap install")
    func debridPresetFlags() {
        #expect(StremioCuratedCatalog.popularPresets.contains {
            StremioCuratedCatalog.isDebridStreamPreset($0) && $0.name == "Torrentio"
        })
        #expect(StremioCuratedCatalog.popularPresets.contains {
            StremioCuratedCatalog.isDebridStreamPreset($0) && $0.name.contains("AIOStreams")
        })
        #expect(StremioCuratedCatalog.popularPresets.first { $0.name == "WatchHub" }
            .map { !StremioCuratedCatalog.isDebridStreamPreset($0) } == true)
    }

    @Test("Debrid URL builder supports cached-only Torrentio options")
    func debridCachedInstallOptions() {
        let base = URL(string: "https://torrentio.strem.fun/manifest.json")!
        let url = StremioDebridURLBuilder.configuredManifestURL(
            for: "com.stremio.torrentio.addon",
            service: .realDebrid,
            token: "TOKEN123",
            baseManifestURL: base,
            options: .fastCached
        )
        #expect(url?.absoluteString.contains("realdebrid=TOKEN123") == true)
        #expect(url?.absoluteString.contains("cached=true") == true)
        #expect(url?.absoluteString.contains("qualityfilter=") == true)
    }

    @Test("Bare manifest stripping removes prior debrid config segments")
    func bareManifestURL() {
        let configured = URL(string: "https://torrentio.strem.fun/realdebrid=OLD/manifest.json")!
        let bare = StremioDebridURLBuilder.bareManifestURL(from: configured)
        #expect(bare.absoluteString == "https://torrentio.strem.fun/manifest.json")
        #expect(StremioDebridURLBuilder.boundService(in: configured) == .realDebrid)
    }

    @Test("Cached debrid markers parse from stream titles")
    func cachedStreamMarkers() throws {
        let json = Data(#"""
        {"name":"[RD+] 1080p","title":"Cached · BluRay","url":"https://cdn.example/a.mp4"}
        """#.utf8)
        let stream = try JSONDecoder().decode(StremioStream.self, from: json)
        #expect(stream.looksDebridCached)
        #expect(stream.playbackKind == .http)
    }

    @Test("Extensionless Debrid HTTP keeps MKV-labeled filenames as candidates")
    func debridHTTPIgnoresFilenameContainer() async throws {
        let client = StremioFixtureClient(streamBody: #"""
        {
          "streams": [
            {"name":"[RD+] 1080p","title":"Cached · MKV · BluRay",
             "url":"https://download.real-debrid.com/d/ABC123/file",
             "behaviorHints":{"filename":"Movie.Name.2024.1080p.BluRay.mkv","notWebReady":false}},
            {"name":"bad","title":"Local MKV","url":"https://cdn.example/movie.mkv",
             "behaviorHints":{"filename":"movie.mkv"}}
          ]
        }
        """#)
        let provider = StremioPlaybackProvider(client: client, baseURL: baseURL)
        let movie = MediaItem(id: "movie", providerID: "tmdb", kind: .movie,
                              title: "Example", imdbID: "tt0133093")
        let candidates = try await provider.candidates(for: .init(request: .init(media: movie, episode: nil)))
        #expect(candidates.count == 1)
        let source = try await candidates[0].resolve()
        #expect(source.url.host?.contains("real-debrid") == true)
    }

    @Test("Magnet URLs without infoHash field route as torrents")
    func magnetURLPlaybackKind() throws {
        let hash = "abcdef0123456789abcdef0123456789abcdef01"
        let json = Data("""
        {"name":"Torrent","url":"magnet:?xt=urn:btih:\(hash)&dn=Example"}
        """.utf8)
        let stream = try JSONDecoder().decode(StremioStream.self, from: json)
        #expect(stream.playbackKind == .torrent)
        #expect(stream.resolvedInfoHash == hash)
    }

    @Test("Installed addon merges stream-resource idPrefixes")
    func mergedStreamIdPrefixes() throws {
        let json = Data(#"""
        {"id":"x","name":"X","resources":[{"name":"stream","types":["movie"],"idPrefixes":["tt"]}],
         "types":["movie","series"],"catalogs":[]}
        """#.utf8)
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: json)
        #expect(InstalledStremioAddon.mergedStreamIdPrefixes(from: manifest) == ["tt"])
        #expect(InstalledStremioAddon.mergedStreamTypes(from: manifest) == ["movie"])
    }

    @Test("One failing Stremio subtitle addon does not wipe others")
    func subtitleAddonIsolation() async throws {
        final class MixedClient: HTTPClientProtocol, @unchecked Sendable {
            func data(for request: URLRequest) async throws -> HTTPResponse {
                let path = request.url?.path ?? ""
                if path.contains("bad") {
                    throw AppError.providerUnavailable("down")
                }
                let body = #"{"subtitles":[{"id":"ok","lang":"eng","url":"https://subs.example/ok.srt"}]}"#
                return HTTPResponse(data: Data(body.utf8), response: HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                )!)
            }
        }
        let provider = StremioSubtitleProvider(
            client: MixedClient(),
            fixedAddons: [
                (id: "bad", name: "Bad", baseURL: URL(string: "https://bad.example/")!),
                (id: "good", name: "Good", baseURL: URL(string: "https://good.example/")!),
            ]
        )
        let request = SubtitleLookupRequest(kind: .movie, imdbID: "tt0133093")
        let subs = try await provider.subtitles(for: request)
        #expect(subs.count == 1)
        #expect(subs[0].providerName == "Good")
    }

    @Test("Meta detail decodes cast and trailers")
    func metaCastTrailers() throws {
        let json = Data(#"""
        {"id":"tt0133093","type":"movie","name":"The Matrix","cast":["Keanu Reeves","Carrie-Anne Moss"],
         "trailers":[{"source":"vKQi3bBA1y8","type":"Trailer"}],"imdb_id":"tt0133093"}
        """#.utf8)
        let detail = try JSONDecoder().decode(StremioMetaDetail.self, from: json)
        let item = detail.asMediaItem(providerID: "stremio:test")
        #expect(item.cast.count == 2)
        #expect(detail.primaryTrailerYouTubeID == "vKQi3bBA1y8")
        #expect(detail.primaryTrailerURL != nil)
    }

    @Test("Stream selection prefers cached debrid links")
    func preferCachedRanking() {
        let cached = PlayableStream(
            candidate: PlaybackCandidate(
                id: "a",
                preference: .init(providerID: "external-streams", serverName: "a", audioLanguage: "en"),
                providerName: "Cached",
                subtitleKind: .unknown,
                displayMetadata: StreamDisplayMetadata(origin: "A", isDebridCached: true),
                resolve: { PlaybackSource(url: URL(string: "https://a.example/a.mp4")!, headers: [:], subtitles: [], preferredPeakBitRate: nil) }
            ),
            source: PlaybackSource(url: URL(string: "https://a.example/a.mp4")!, headers: [:], subtitles: [], preferredPeakBitRate: nil),
            qualities: []
        )
        let uncached = PlayableStream(
            candidate: PlaybackCandidate(
                id: "b",
                preference: .init(providerID: "external-streams", serverName: "b", audioLanguage: "en"),
                providerName: "Uncached",
                subtitleKind: .unknown,
                displayMetadata: StreamDisplayMetadata(origin: "B", isDebridCached: false),
                resolve: { PlaybackSource(url: URL(string: "https://b.example/b.mp4")!, headers: [:], subtitles: [], preferredPeakBitRate: nil) }
            ),
            source: PlaybackSource(url: URL(string: "https://b.example/b.mp4")!, headers: [:], subtitles: [], preferredPeakBitRate: nil),
            qualities: []
        )
        var policy = StreamSelectionPolicy()
        policy.preferDebridCached = true
        #expect(policy.best(in: [uncached, cached])?.id == "a")
    }

    @Test("Diagnostics explain invalid-token when debrid configured but torrents only")
    func diagnosticsTokenHint() {
        var diag = StremioResolveDiagnostics()
        diag.queriedAddons = 2
        diag.skippedTorrent = 12
        diag.debridConfigured = true
        #expect(diag.userFacingSummary.lowercased().contains("validate"))
        #expect(diag.userFacingSummary.lowercased().contains("rebind"))
    }

    @Test("Manifest configurationURL resolves relative to base")
    func configurationURLRelative() throws {
        let json = Data(#"""
        {"id":"x","name":"X","resources":["stream"],"types":["movie"],
         "behaviorHints":{"configurable":true},"catalogs":[]}
        """#.utf8)
        let manifest = try JSONDecoder().decode(StremioManifest.self, from: json)
        let base = URL(string: "https://torrentio.strem.fun/")!
        #expect(manifest.configurationURL(relativeTo: base)?.absoluteString.hasSuffix("/configure") == true)
    }

    @Test("fileIdx decodes on torrent streams")
    func fileIdxDecode() throws {
        let json = Data(#"""
        {"name":"Torrent","infoHash":"abcdefghijklmnopqrstuvwxyz1234567890abcd","fileIdx":2}
        """#.utf8)
        let stream = try JSONDecoder().decode(StremioStream.self, from: json)
        #expect(stream.fileIdx == 2)
        #expect(stream.playbackKind == .torrent)
    }
}

private final class StremioFixtureClient: HTTPClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private let streamBody: String
    private let subtitleBody: String
    private let catalogBody: String
    private let manifestBody: String
    var requestedPaths: [String] { lock.withLock { paths } }

    init(
        streamBody: String = #"{"streams":[]}"#,
        subtitleBody: String = #"{"subtitles":[]}"#,
        catalogBody: String = #"{"metas":[]}"#,
        manifestBody: String = #"""
        {"id":"test.addon","name":"Test","version":"1.0.0","resources":["stream","catalog"],
         "types":["movie","series"],"catalogs":[{"type":"movie","id":"top","name":"Top"}]}
        """#
    ) {
        self.streamBody = streamBody
        self.subtitleBody = subtitleBody
        self.catalogBody = catalogBody
        self.manifestBody = manifestBody
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let url = try #require(request.url)
        lock.withLock { paths.append(url.path) }
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let body: String
        if url.path.contains("/subtitles/") {
            body = subtitleBody
        } else if url.path.contains("/catalog/") {
            body = catalogBody
        } else if url.path.hasSuffix("/manifest.json") {
            body = manifestBody
        } else {
            body = streamBody
        }
        return HTTPResponse(data: Data(body.utf8), response: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        )!)
    }
}
