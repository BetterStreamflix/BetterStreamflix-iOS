@preconcurrency import AVKit
@preconcurrency import AVFoundation
@preconcurrency import Network
import Combine
@preconcurrency import MediaPlayer
import SwiftUI
import UIKit

final class PlaybackIntentPlayer: AVPlayer {
    struct ControlSnapshot: Sendable {
        let revision: Int
        let shouldPlay: Bool?
    }

    private let controlLock = NSLock()
    nonisolated(unsafe) private var controlState = ControlSnapshot(
        revision: 0,
        shouldPlay: nil
    )

    nonisolated var controlSnapshot: ControlSnapshot {
        controlLock.withLock { controlState }
    }

    nonisolated private func recordControl(_ shouldPlay: Bool) {
        controlLock.withLock {
            controlState = ControlSnapshot(
                revision: controlState.revision &+ 1,
                shouldPlay: shouldPlay
            )
        }
    }

    override func play() {
        recordControl(true)
        super.play()
    }

    override func playImmediately(atRate rate: Float) {
        recordControl(true)
        super.playImmediately(atRate: rate)
    }

    override func pause() {
        recordControl(false)
        super.pause()
    }
}

@MainActor
final class HLSSubtitleLoopbackServer {
    private struct Route {
        let content: Data
        let contentType: String
    }

    private var listener: NWListener?
    private var listenerPort: NWEndpoint.Port?
    private var listenerError: NWError?
    private var routes: [String: Route] = [:]
    private var requestBuffers: [ObjectIdentifier: Data] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    deinit {
        listener?.cancel()
        for connection in connections.values { connection.cancel() }
    }

    func publish(_ asset: InjectedHLSSubtitleAsset) async throws -> URL {
        let port = try await startIfNeeded()
        let token = UUID().uuidString
        guard let rootURL = URL(string: "http://127.0.0.1:\(port.rawValue)/\(token)/") else {
            throw AppError.invalidURL
        }

        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: asset.workingDirectory,
                includingPropertiesForKeys: nil
            )
            let localURLs = Dictionary(uniqueKeysWithValues: files.map { file in
                (file.absoluteString, rootURL.appending(path: file.lastPathComponent).absoluteString)
            })
            clear()
            for file in files {
                var content = try Data(contentsOf: file)
                let contentType: String
                if file.pathExtension.lowercased() == "m3u8" {
                    guard var playlist = String(data: content, encoding: .utf8) else {
                        throw AppError.decoding("Injected HLS playlist")
                    }
                    for (fileURL, routeURL) in localURLs {
                        playlist = playlist.replacingOccurrences(of: fileURL, with: routeURL)
                    }
                    content = Data(playlist.utf8)
                    contentType = "application/vnd.apple.mpegurl"
                } else if file.pathExtension.lowercased() == "ts" {
                    contentType = "video/mp2t"
                } else {
                    contentType = "text/vtt; charset=utf-8"
                }
                let routeURL = rootURL.appending(path: file.lastPathComponent)
                routes[routeURL.path] = Route(content: content, contentType: contentType)
            }
            try? FileManager.default.removeItem(at: asset.workingDirectory)
            return rootURL.appending(path: asset.masterPlaylistURL.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: asset.workingDirectory)
            throw error
        }
    }

    func clear() {
        routes.removeAll(keepingCapacity: true)
    }

    private func startIfNeeded() async throws -> NWEndpoint.Port {
        if let listenerPort { return listenerPort }
        if let listenerError { throw listenerError }
        if listener == nil {
            let parameters = NWParameters.tcp
            // Bind to loopback explicitly. acceptLocalOnly restricts peers to the
            // local link and can reject loopback requests before they are accepted.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listenerPort = listener.port
                    case .failed(let error):
                        self.listenerError = error
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: .main)
        }

        for _ in 0..<200 {
            if let listenerPort { return listenerPort }
            if let listenerError { throw listenerError }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw AppError.providerUnavailable("The local subtitle server did not start.")
    }

    private func accept(_ connection: NWConnection) {
        let identifier = ObjectIdentifier(connection)
        connections[identifier] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled:
                    self?.connections.removeValue(forKey: identifier)
                    self?.requestBuffers.removeValue(forKey: identifier)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                let identifier = ObjectIdentifier(connection)
                if let data { self.requestBuffers[identifier, default: Data()].append(data) }
                if self.requestBuffers[identifier]?.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.respond(
                        to: connection,
                        request: self.requestBuffers.removeValue(forKey: identifier) ?? Data()
                    )
                } else if isComplete || error != nil {
                    self.requestBuffers.removeValue(forKey: identifier)
                    connection.cancel()
                } else {
                    self.receiveRequest(on: connection)
                }
            }
        }
    }

    private func respond(to connection: NWConnection, request: Data) {
        guard let requestText = String(data: request, encoding: .utf8),
              let requestLine = requestText.components(separatedBy: "\r\n").first else {
            send(status: "400 Bad Request", route: nil, includeBody: false, on: connection)
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2,
              parts[0] == "GET" || parts[0] == "HEAD",
              let components = URLComponents(string: String(parts[1])) else {
            send(status: "400 Bad Request", route: nil, includeBody: false, on: connection)
            return
        }
        guard let route = routes[components.path] else {
            send(status: "404 Not Found", route: nil, includeBody: false, on: connection)
            return
        }
        send(status: "200 OK", route: route, includeBody: parts[0] == "GET", on: connection)
    }

    private func send(
        status: String,
        route: Route?,
        includeBody: Bool,
        on connection: NWConnection
    ) {
        let body = route?.content ?? Data()
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(route?.contentType ?? "text/plain")\r
        Content-Length: \(body.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        if includeBody { response.append(body) }
        // Finish the HTTP response gracefully. Cancelling immediately after queuing
        // the bytes can reset the socket before AVPlayer receives the response.
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
            } else {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                    connection.cancel()
                }
            }
        })
    }
}

struct SubtitlePickerEntry: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case off
        case track
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let providerName: String
    let languageCode: String?
    let isSelected: Bool
    let isSynced: Bool
    let syncKey: String?

    static func off(isSelected: Bool) -> SubtitlePickerEntry {
        SubtitlePickerEntry(
            id: "__off__",
            kind: .off,
            title: "Off",
            subtitle: "Hide captions for this title",
            providerName: "",
            languageCode: nil,
            isSelected: isSelected,
            isSynced: false,
            syncKey: nil
        )
    }
}

struct SubtitleStudioTrack: Identifiable, Sendable {
    let source: SubtitleSource
    let cues: [SubtitleCue]

    var id: String { source.syncKey }
    var displayName: String { "\(source.providerName) · \(source.label)" }

    func text(at playbackTime: Double, offset: Double) -> String? {
        let sourceTime = playbackTime - offset
        return cues.first {
            $0.startTime <= sourceTime && sourceTime < $0.endTime
        }?.text
    }
}

struct SubtitleStudioContext: Identifiable, Sendable {
    let selectedTrackID: String
    let offset: Double
    let selectedVersionID: UUID?

    var id: String { selectedTrackID }
}

enum SubtitleSelectionLookup {
    static func make(
        displayNames: [String],
        languageTags: [String],
        renditions: [HLSSubtitleRendition]
    ) -> [String: HLSSubtitleRendition] {
        var result = Dictionary(uniqueKeysWithValues: zip(displayNames, renditions))
        let tagCounts = Dictionary(grouping: languageTags.map { $0.lowercased() }, by: { $0 })
            .mapValues(\.count)
        for (languageTag, rendition) in zip(languageTags, renditions) {
            let normalizedTag = languageTag.lowercased()
            if tagCounts[normalizedTag] == 1 { result[normalizedTag] = rendition }
        }
        return result
    }
}

@MainActor
final class PlayerSession: ObservableObject {
    let player = PlaybackIntentPlayer()
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var availableQualities: [StreamQuality] = []
    @Published private(set) var selectedQuality: StreamQuality?
    @Published private(set) var activeContentID: String?
    @Published private(set) var subtitleTimingOffset: Double = 0
    @Published private(set) var canAdjustSubtitleTiming = false
    @Published private(set) var canOpenSubtitleStudio = false
    @Published private(set) var subtitleStudioTracks: [SubtitleStudioTrack] = []
    @Published private(set) var subtitleStudioPosition: Double = 0
    @Published private(set) var isSubtitleStudioSeeking = false
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var isBuffering = false
    @Published private(set) var playbackErrorMessage: String?
    @Published private(set) var playbackState: PlaybackSessionState = .idle
    @Published private(set) var recoveryAttemptCount = 0
    @Published private(set) var subtitlePickerEntries: [SubtitlePickerEntry] = []
    @Published private(set) var isSubtitleDiscoveryIdleHint = false

    var onEnded: (() -> Void)?
    var onSourceRefreshNeeded: (() async -> Bool)?
    var onSubtitleVisibilityChanged: ((Bool) -> Void)?
    var onSubtitleSelectionChanged: ((SubtitleSelectionPreference) -> Void)?
    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var studioTimeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaSelectionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var playbackStalledObserver: NSObjectProtocol?
    nonisolated(unsafe) private var playbackErrorLogObserver: NSObjectProtocol?
    nonisolated(unsafe) private var failedToPlayToEndObserver: NSObjectProtocol?
    nonisolated(unsafe) private var timeJumpedObserver: NSObjectProtocol?
    nonisolated(unsafe) private var audioInterruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var audioRouteChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var defaultRateObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var timeControlStatusObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var playbackBufferEmptyObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var playbackLikelyToKeepUpObservation: NSKeyValueObservation?
    nonisolated(unsafe) private var itemStatusObservation: NSKeyValueObservation?
    private var mediaOptionsTask: Task<Void, Never>?
    private var mediaSelectionGeneration = UUID()
    private var subtitleAdjustmentTask: Task<Void, Never>?
    private var qualitySwitchTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var recoveryWatchdogTask: Task<Void, Never>?
    private var sourceRefreshTask: Task<Void, Never>?
    private var sourceExpirationTask: Task<Void, Never>?
    private var nowPlayingContentID: String?
    private var nowPlayingTitle: String?
    private var nowPlayingSubtitle: String?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var injectedSubtitleNames: Set<String> = []
    private var injectedSubtitleLanguageTags: Set<String> = []
    private var subtitleRenditions: [HLSSubtitleRendition] = []
    private var subtitleRenditionsByDisplayName: [String: HLSSubtitleRendition] = [:]
    private var subtitleRenditionsBySelectionID: [String: HLSSubtitleRendition] = [:]
    private var subtitlePlaybackSource: PlaybackSource?
    private var subtitleSyncVersions: [SubtitleSyncVersion] = []
    private var studioPreviousSubtitleDisplayName: String?
    private var studioWasPlaying = false
    private var subtitleStudioSeekToken = UUID()
    private var appliedSubtitleTimingOffset: Double = 0
    private var primarySubtitleLanguage = ""
    private var secondarySubtitleLanguage = ""

    private var audioLanguage = "en"
    private var subtitleVisibilityBaseline: Bool?
    private var subtitleUserRequestedOn = true
    private var subtitleVisibilityObservation = SubtitleVisibilityObservation()
    private var subtitleSelectionAuthority = SubtitleSelectionAuthority()
    private var isApplyingPreferredLanguages = false
    private var isStabilizingMediaSelection = false
    private var playbackWasRequested = false
    private var shouldResumeAfterBuffering = false
    private var isPreparingPlayback = false
    private var nextReplacementShouldPlay: Bool?
    private var currentSourceURL: URL?
    private var currentSourceExpiresAt: Date?
    private var sourceRefreshRequestedForURL: URL?
    private var needsSourceRefreshAfterBackground = false
    private var automaticSourceRefreshAttempts = 0
    private var recoveryBaselinePosition = 0.0
    private var lastObservedBufferEnd = 0.0
    /// Cooldown so a flapping error log cannot thrash through refresh attempts.
    private var lastItemFailureAt: Date?
    private var stagnantBufferChecks = 0
    private var seekRecoveryGraceUntil: Date?
    private var playbackSeekState = PlaybackSeekState()
    private var wasPlayingBeforeInterruption = false
    private var qualityPreferenceInitialized = false
    private var preferredQualityHeight: Int?
    private var automaticPeakBitRate: Double?
    private var currentPlaybackSource: PlaybackSource?
    private var currentExternalSubtitles: [SubtitleSource] = []
    private let playlistInspector = HLSPlaylistInspector()
    private let subtitleClient: any HTTPClientProtocol
    private let subtitleCache: SubtitleRenditionCache
    private var subtitleServer = HLSSubtitleLoopbackServer()
    private var sourceSwitchGeneration = UUID()
    private var pendingSourceSwitchTime: Double?
    private var pendingSourceSwitchShouldPlay: Bool?
    private var pendingSourceSwitchRate: Float?
    private var pendingSourceSwitchItem: AVPlayerItem?
    private var isSourceSwitching = false
    private var startupPlayingLogged = false
    private var playbackGeneration = UUID()
    private var automaticEnrichmentUsed = false
    private var backgroundEnrichmentTask: Task<Void, Never>?
    private var backgroundEnrichmentDeadline: ContinuousClock.Instant?
    private var automaticEnrichmentTask: Task<Void, Never>?
    private var automaticEnrichmentInProgressGeneration: UUID?
    private var currentContentID: String?
    private var currentSubtitleLoadingMode: SubtitleLoadingMode = .fast
    private var rememberedSubtitleSelection: SubtitleSelectionPreference?
    private var automaticallySelectLatestSubtitleSync = true
    private var nativeSubtitleDescriptors: [NativeHLSSubtitleDescriptor] = []
    private var nativeDescriptorTask: Task<Void, Never>?
    private var isSubtitleStudioActive = false
    private(set) var automaticSubtitleEnrichmentCount = 0
    private let audioSessionController = AudioSessionController()

    init(
        subtitleClient: any HTTPClientProtocol = HTTPClient(),
        subtitleCache: SubtitleRenditionCache = .shared
    ) {
        self.subtitleClient = subtitleClient
        self.subtitleCache = subtitleCache
        player.allowsExternalPlayback = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, change in
            guard let rate = change.newValue, rate > 0 else { return }
            Task { @MainActor [weak self] in self?.recordPlaybackRate(rate) }
        }
        defaultRateObservation = player.observe(\.defaultRate, options: [.new]) { [weak self] _, change in
            guard let rate = change.newValue, rate > 0 else { return }
            Task { @MainActor [weak self] in self?.recordPlaybackRate(rate) }
        }
        timeControlStatusObservation =
            player.observe(
                \.timeControlStatus,
                options: [.initial, .new]
            ) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    self.refreshPlaybackState()

                    if self.player.timeControlStatus == .playing,
                       !self.startupPlayingLogged {

                        self.startupPlayingLogged = true

                        PlaybackStartupTrace.mark(
                            "AVPlayer PLAYING"
                        )
                    }
                }
            }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let value = self.player.currentItem?.duration.seconds ?? 0
                self.duration = value.isFinite ? value : 0
                self.recordPlaybackRate(self.player.rate > 0 ? self.player.rate : self.player.defaultRate)
                if self.automaticSourceRefreshAttempts > 0,
                   self.player.timeControlStatus == .playing,
                   self.position >= self.recoveryBaselinePosition + 5 {
                    self.automaticSourceRefreshAttempts = 0
                    self.recoveryAttemptCount = 0
                    self.playbackErrorMessage = nil
                }
                self.publishNowPlayingInfo()
            }
        }
        observeAudioSessionEvents()
    }

    deinit {
        mediaOptionsTask?.cancel()
        subtitleAdjustmentTask?.cancel()
        qualitySwitchTask?.cancel()
        nowPlayingArtworkTask?.cancel()
        recoveryWatchdogTask?.cancel()
        sourceRefreshTask?.cancel()
        sourceExpirationTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let studioTimeObserver { player.removeTimeObserver(studioTimeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let mediaSelectionObserver { NotificationCenter.default.removeObserver(mediaSelectionObserver) }
        if let playbackStalledObserver { NotificationCenter.default.removeObserver(playbackStalledObserver) }
        if let playbackErrorLogObserver { NotificationCenter.default.removeObserver(playbackErrorLogObserver) }
        if let failedToPlayToEndObserver { NotificationCenter.default.removeObserver(failedToPlayToEndObserver) }
        if let timeJumpedObserver { NotificationCenter.default.removeObserver(timeJumpedObserver) }
        if let audioInterruptionObserver { NotificationCenter.default.removeObserver(audioInterruptionObserver) }
        if let audioRouteChangeObserver { NotificationCenter.default.removeObserver(audioRouteChangeObserver) }
    }

    func load(
        request playbackRequest: PlaybackRequest,
        source: PlaybackSource,
        resumeAt: Double,
        primarySubtitleLanguage: String,
        secondarySubtitleLanguage: String,
        audioLanguage: String,
        externalSubtitles: [SubtitleSource],
        subtitleSyncVersions: [SubtitleSyncVersion],
        automaticallySelectLatestSubtitleSync: Bool,
        subtitlesEnabled: Bool,
        defaultQualityHeight: Int,
        defaultPlaybackRate: Float,
        subtitleLoadingMode: SubtitleLoadingMode = .fast,
        subtitleSelectionPreference: SubtitleSelectionPreference? = nil
    ) async {
        let startupPerfStart = PlaybackStartupTrace.now()

        PlaybackStartupTrace.mark(
            "PlayerSession LOAD START"
        )

        startupPlayingLogged = false
        let playbackGeneration = UUID()
        self.playbackGeneration = playbackGeneration
        automaticEnrichmentUsed = false
        automaticSubtitleEnrichmentCount = 0
        backgroundEnrichmentTask?.cancel()
        backgroundEnrichmentTask = nil
        automaticEnrichmentTask?.cancel()
        automaticEnrichmentTask = nil
        automaticEnrichmentInProgressGeneration = nil
        backgroundEnrichmentDeadline = ContinuousClock().now.advanced(by: .seconds(15))
        nativeDescriptorTask?.cancel()
        nativeSubtitleDescriptors = []
        currentContentID = playbackRequest.contentID
        currentSubtitleLoadingMode = subtitleLoadingMode
        rememberedSubtitleSelection = subtitleSelectionPreference
        self.automaticallySelectLatestSubtitleSync = automaticallySelectLatestSubtitleSync
        subtitleUserRequestedOn = subtitlesEnabled
        self.primarySubtitleLanguage = primarySubtitleLanguage
        self.secondarySubtitleLanguage = secondarySubtitleLanguage
        self.audioLanguage = audioLanguage
        sourceSwitchGeneration = UUID()
        pendingSourceSwitchTime = nil
        pendingSourceSwitchShouldPlay = nil
        pendingSourceSwitchRate = nil
        pendingSourceSwitchItem = nil
        isSourceSwitching = false
        // Recovery may replace an item while the user is intentionally paused.
        // Consume the intent before asynchronous subtitle preparation so the
        // replacement cannot unexpectedly start itself later.
        let shouldPlay = nextReplacementShouldPlay ?? true
        nextReplacementShouldPlay = nil
        recoveryWatchdogTask?.cancel()
        qualitySwitchTask?.cancel()
        playbackState = .preparing
        isBuffering = shouldPlay
        playbackErrorMessage = nil
        await audioSessionController.activateForPlayback()
        guard !Task.isCancelled else { return }
        configureNowPlaying(for: playbackRequest)
        mediaOptionsTask?.cancel()
        subtitleAdjustmentTask?.cancel()
        removeInjectedSubtitleAsset()
        subtitleTimingOffset = 0
        appliedSubtitleTimingOffset = 0
        self.subtitleSyncVersions = subtitleSyncVersions
        let preparedSource = source.preferredForSubtitleLanguage(primarySubtitleLanguage)
        nativeDescriptorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let descriptors = await HLSNativeSubtitleLoader.descriptors(
                from: preparedSource,
                client: self.subtitleClient
            )
            guard self.playbackGeneration == playbackGeneration else { return }
            self.nativeSubtitleDescriptors = descriptors
            self.canOpenSubtitleStudio = !descriptors.isEmpty || !self.subtitleStudioTracks.isEmpty
            await self.prepareRememberedNativeSyncIfNeeded(
                descriptors: descriptors,
                source: preparedSource,
                contentID: playbackRequest.contentID,
                generation: playbackGeneration
            )
        }
        let qualityPerfStart =
            PlaybackStartupTrace.now()
        let qualities = await playlistInspector.availableQualities(for: preparedSource)
        PlaybackStartupTrace.mark(
            "PlayerSession qualities READY duration=\(PlaybackStartupTrace.duration(since: qualityPerfStart))ms"
        )
        guard !Task.isCancelled else { return }
        availableQualities = qualities
        if !qualityPreferenceInitialized {
            preferredQualityHeight = defaultQualityHeight > 0 ? defaultQualityHeight : nil
            qualityPreferenceInitialized = true
        }
        selectedQuality = preferredQualityHeight.flatMap {
            StreamQuality.closest(to: $0, in: qualities)
        }
        let subtitlePerfStart =
            PlaybackStartupTrace.now()

        PlaybackStartupTrace.mark(
            "PlayerSession subtitle injection START external=\(externalSubtitles.count)"
        )
        let asset = await assetByInjectingSubtitles(
            externalSubtitles,
            into: preparedSource,
            selectedQuality: selectedQuality,
            contentID: playbackRequest.contentID,
            loadingMode: subtitleLoadingMode,
            preparePreferredSubtitle: subtitlesEnabled
        )
        PlaybackStartupTrace.mark(
            "PlayerSession subtitle injection DONE duration=\(PlaybackStartupTrace.duration(since: subtitlePerfStart))ms"
        )
        guard !Task.isCancelled else { return }
        automaticPeakBitRate = source.preferredPeakBitRate
        currentPlaybackSource = preparedSource
        currentExternalSubtitles = externalSubtitles
        sourceRefreshRequestedForURL = nil
        currentSourceURL = source.url
        currentSourceExpiresAt = Self.expirationDate(in: source.url)
        needsSourceRefreshAfterBackground = false
        player.defaultRate = defaultPlaybackRate
        playbackRate = Double(defaultPlaybackRate)
        let rememberedSyncVersionID = subtitleSelectionPreference?.syncVersionID.flatMap { id in
            subtitleSyncVersions.contains(where: { $0.id == id }) ? id : nil
        }
        let latestRememberedBaseVersionID = subtitlesEnabled && automaticallySelectLatestSubtitleSync
            ? subtitleSyncVersions
                .filter { version in
                    subtitleSelectionPreference.map {
                        version.subtitleKey == $0.baseSubtitleKey
                    } ?? true
                }
                .sorted { $0.createdAt > $1.createdAt }
                .compactMap { version in
                    selectionID(forSyncVersionID: version.id).map { (version.id, $0) }
                }
                .first
            : nil
        let preferredSelectionID = rememberedSyncVersionID.flatMap(selectionID(forSyncVersionID:))
            ?? subtitleSelectionPreference.flatMap { selectionID(forBaseSubtitleKey: $0.baseSubtitleKey) }
            ?? latestRememberedBaseVersionID?.1
        subtitleVisibilityBaseline = subtitlesEnabled
        PlaybackStartupTrace.mark(
            "PlayerSession replaceCurrentItem total=\(PlaybackStartupTrace.duration(since: startupPerfStart))ms"
        )
        replaceCurrentItem(
            with: asset,
            resumeAt: resumeAt,
            shouldPlay: shouldPlay,
            playbackRate: defaultPlaybackRate,
            preferredSubtitleSelectionID: subtitlesEnabled
                ? preferredSelectionID
                : "__subtitles_off__"
        )
        activeContentID = playbackRequest.contentID
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.nativeDescriptorTask?.value
            guard self.playbackGeneration == playbackGeneration else { return }
            self.updateExternalSubtitles(externalSubtitles)
        }
    }

    func updateExternalSubtitles(_ subtitles: [SubtitleSource]) {
        var seen = Set<String>()
        let unique = subtitles.filter { seen.insert($0.syncKey).inserted }
        currentExternalSubtitles = unique
        guard let contentID = currentContentID,
              let source = currentPlaybackSource else { return }

        let generation = playbackGeneration
        let deadline = backgroundEnrichmentDeadline
            ?? ContinuousClock().now.advanced(by: .seconds(15))
        backgroundEnrichmentTask?.cancel()
        backgroundEnrichmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let clock = ContinuousClock()
            guard clock.now < deadline else {
                SubtitleDiagnostics.logger.info(
                    "SUBTITLE PERF background enrichment deadline EXPIRED"
                )
                _ = await self.loadSubtitleRenditions(
                    unique,
                    contentID: contentID,
                    deadline: clock.now.advanced(by: .seconds(10)),
                    perTrackBudget: .seconds(10)
                )
                return
            }
            let cached = await self.sourceCorrectCachedRenditions(
                contentID: contentID,
                source: source
            )
            let preferredKey = self.preferredExternalSubtitle(in: unique)?.syncKey
            let downloaded = await self.loadSubtitleRenditions(
                unique,
                contentID: contentID,
                deadline: deadline,
                perTrackBudget: .seconds(10),
                onReady: { [weak self] rendition in
                    guard let self,
                          rendition.subtitle.syncKey == preferredKey,
                          self.playbackGeneration == generation,
                          self.automaticEnrichmentTask == nil else { return }
                    let ready = cached + [rendition]
                    self.automaticEnrichmentTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.attemptAutomaticEnrichment(
                            ready,
                            subtitles: unique,
                            source: source,
                            contentID: contentID,
                            generation: generation,
                            deadline: deadline
                        )
                        if self.playbackGeneration == generation {
                            self.automaticEnrichmentTask = nil
                        }
                    }
                }
            )
            var loadedByKey = Dictionary(
                uniqueKeysWithValues: cached.map { ($0.subtitle.syncKey, $0) }
            )
            for rendition in downloaded {
                loadedByKey[rendition.subtitle.syncKey] = rendition
            }
            let loaded = Array(loadedByKey.values)
            guard self.playbackGeneration == generation else {
                SubtitleDiagnostics.logger.info("SUBTITLE PERF player enrichment CANCELLED stale generation")
                return
            }
            await self.automaticEnrichmentTask?.value
            await self.attemptAutomaticEnrichment(
                loaded,
                subtitles: unique,
                source: source,
                contentID: contentID,
                generation: generation,
                deadline: deadline
            )
        }
    }

    private func attemptAutomaticEnrichment(
        _ readyRenditions: [HLSSubtitleRendition],
        subtitles: [SubtitleSource],
        source: PlaybackSource,
        contentID: String,
        generation: UUID,
        deadline: ContinuousClock.Instant
    ) async {
        guard !Task.isCancelled,
              playbackGeneration == generation,
              !automaticEnrichmentUsed,
              automaticEnrichmentInProgressGeneration == nil,
              player.currentItem != nil else { return }

        let existingBase = subtitleRenditions.filter { $0.syncVersionID == nil }
        var byKey = Dictionary(
            uniqueKeysWithValues: existingBase.map { ($0.subtitle.syncKey, $0) }
        )
        for rendition in readyRenditions {
            byKey[rendition.subtitle.syncKey] = rendition
        }
        let consolidated = sortSubtitleRenditions(Array(byKey.values))
        let existingKeys = Set(existingBase.map { $0.subtitle.syncKey })
        guard consolidated.contains(where: { !existingKeys.contains($0.subtitle.syncKey) }) else {
            return
        }
        SubtitleDiagnostics.logger.info(
            "SUBTITLE PERF background enrichment READY tracks=\(consolidated.count)"
        )
        automaticEnrichmentInProgressGeneration = generation
        defer {
            if automaticEnrichmentInProgressGeneration == generation {
                automaticEnrichmentInProgressGeneration = nil
            }
        }

        let clock = ContinuousClock()
        while !Task.isCancelled,
              playbackGeneration == generation,
              clock.now < deadline,
              (player.currentItem?.isPlaybackLikelyToKeepUp == false
                || playbackSeekState.latestRequest != nil
                || isSourceSwitching
                || isSubtitleStudioActive
                || isSubtitleStudioSeeking) {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        guard !Task.isCancelled,
              playbackGeneration == generation,
              clock.now < deadline,
              playbackSeekState.latestRequest == nil,
              !isSourceSwitching,
              !isSubtitleStudioActive,
              !isSubtitleStudioSeeking else {
            SubtitleDiagnostics.logger.info(
                "SUBTITLE PERF player enrichment CANCELLED or deadline EXPIRED"
            )
            return
        }

        let oldItem = player.currentItem
        let oldServer = subtitleServer
        let oldNames = injectedSubtitleNames
        let oldLanguageTags = injectedSubtitleLanguageTags
        let oldRenditions = subtitleRenditions
        let oldByName = subtitleRenditionsByDisplayName
        let oldByID = subtitleRenditionsBySelectionID
        let oldStudioTracks = subtitleStudioTracks
        let oldSubtitleSource = subtitlePlaybackSource
        let oldCanStudio = canOpenSubtitleStudio
        let oldCanAdjust = canAdjustSubtitleTiming
        let selectedSubtitleID = await selectedSubtitleSelectionID()
        let selectedSubtitleName = await selectedSubtitleDisplayName()
        let selectedRendition = selectedSubtitleID.flatMap { oldByID[$0] }
            ?? selectedSubtitleName.flatMap { oldByName[$0] }
        guard !Task.isCancelled,
              playbackGeneration == generation,
              player.currentItem === oldItem else { return }
        subtitleServer = HLSSubtitleLoopbackServer()
        SubtitleDiagnostics.logger.info("SUBTITLE PERF player enrichment START")
        let asset = await assetByInjectingSubtitles(
            subtitles,
            into: source,
            selectedQuality: selectedQuality,
            generation: sourceSwitchGeneration,
            contentID: contentID,
            loadingMode: .completeBeforePlayback,
            preparedRenditions: consolidated
        )
        guard !Task.isCancelled,
              playbackGeneration == generation,
              player.currentItem === oldItem,
              asset.url != source.url,
              playbackSeekState.latestRequest == nil,
              !isSourceSwitching,
              !isSubtitleStudioActive else {
            if playbackGeneration == generation, player.currentItem === oldItem {
                subtitleServer = oldServer
                injectedSubtitleNames = oldNames
                injectedSubtitleLanguageTags = oldLanguageTags
                subtitleRenditions = oldRenditions
                subtitleRenditionsByDisplayName = oldByName
                subtitleRenditionsBySelectionID = oldByID
                subtitleStudioTracks = oldStudioTracks
                subtitlePlaybackSource = oldSubtitleSource
                canOpenSubtitleStudio = oldCanStudio
                canAdjustSubtitleTiming = oldCanAdjust
            }
            SubtitleDiagnostics.logger.info("SUBTITLE PERF player enrichment CANCELLED")
            return
        }

        if let oldItem,
           let audioGroup = try? await oldItem.asset.loadMediaSelectionGroup(for: .audible),
           let selectedAudio = oldItem.currentMediaSelection.selectedMediaOption(in: audioGroup),
           let selectedLanguage = selectedAudio.extendedLanguageTag
                ?? selectedAudio.locale?.identifier {
            audioLanguage = selectedLanguage
        }
        guard !Task.isCancelled,
              playbackGeneration == generation,
              player.currentItem === oldItem,
              playbackSeekState.latestRequest == nil,
              !isSourceSwitching,
              !isSubtitleStudioActive else {
            if playbackGeneration == generation, player.currentItem === oldItem {
                subtitleServer = oldServer
                injectedSubtitleNames = oldNames
                injectedSubtitleLanguageTags = oldLanguageTags
                subtitleRenditions = oldRenditions
                subtitleRenditionsByDisplayName = oldByName
                subtitleRenditionsBySelectionID = oldByID
                subtitleStudioTracks = oldStudioTracks
                subtitlePlaybackSource = oldSubtitleSource
                canOpenSubtitleStudio = oldCanStudio
                canAdjustSubtitleTiming = oldCanAdjust
            }
            return
        }
        let liveTime = oldItem?.currentTime().seconds
        let resumeAt = liveTime?.isFinite == true ? liveTime ?? position : position
        let shouldPlay = player.rate > 0 || player.timeControlStatus != .paused
        let rate = player.rate > 0 ? player.rate : player.defaultRate
        let restoredSubtitleID = subtitleUserRequestedOn
            ? selectedRendition.flatMap { rendition in
                rendition.syncVersionID.flatMap(selectionID(forSyncVersionID:))
                    ?? selectionID(forBaseSubtitleKey: rendition.subtitle.syncKey)
            }
                ?? selectedSubtitleID
                ?? rememberedSubtitleSelection?.syncVersionID.flatMap(
                    selectionID(forSyncVersionID:)
                )
                ?? rememberedSubtitleSelection.flatMap {
                    selectionID(forBaseSubtitleKey: $0.baseSubtitleKey)
                }
            : "__subtitles_off__"
        automaticEnrichmentUsed = true
        automaticSubtitleEnrichmentCount += 1
        replaceCurrentItem(
            with: asset,
            resumeAt: resumeAt,
            shouldPlay: shouldPlay,
            playbackRate: rate,
            preferredSubtitleDisplayName: selectedSubtitleName,
            preferredSubtitleSelectionID: restoredSubtitleID,
            seekTolerance: .zero
        )
        SubtitleDiagnostics.logger.info("SUBTITLE PERF player enrichment DONE")
        withExtendedLifetime(oldServer) { }
    }

    func stop() {
        sourceSwitchGeneration = UUID()
        playbackGeneration = UUID()
        backgroundEnrichmentTask?.cancel()
        backgroundEnrichmentTask = nil
        automaticEnrichmentTask?.cancel()
        automaticEnrichmentTask = nil
        automaticEnrichmentInProgressGeneration = nil
        backgroundEnrichmentDeadline = nil
        nativeDescriptorTask?.cancel()
        nativeDescriptorTask = nil
        subtitleAdjustmentTask?.cancel()
        qualitySwitchTask?.cancel()
        nowPlayingArtworkTask?.cancel()
        recoveryWatchdogTask?.cancel()
        sourceRefreshTask?.cancel()
        sourceExpirationTask?.cancel()
        playbackWasRequested = false
        shouldResumeAfterBuffering = false
        isPreparingPlayback = false
        nextReplacementShouldPlay = nil
        pendingSourceSwitchTime = nil
        pendingSourceSwitchShouldPlay = nil
        pendingSourceSwitchRate = nil
        pendingSourceSwitchItem = nil
        isSourceSwitching = false
        currentSourceURL = nil
        currentPlaybackSource = nil
        currentExternalSubtitles = []
        currentContentID = nil
        activeContentID = nil
        nativeSubtitleDescriptors = []
        automaticEnrichmentUsed = false
        isSubtitleStudioActive = false
        subtitleSyncVersions = []
        subtitleStudioTracks = []
        isSubtitleStudioSeeking = false
        currentSourceExpiresAt = nil
        sourceRefreshRequestedForURL = nil
        needsSourceRefreshAfterBackground = false
        automaticSourceRefreshAttempts = 0
        recoveryAttemptCount = 0
        playbackErrorMessage = nil
        player.pause()
        removeStudioTimeObserver()
        isBuffering = false
        playbackState = .idle
        seekRecoveryGraceUntil = nil
        playbackSeekState.reset()
        removeInjectedSubtitleAsset()
        clearNowPlaying()
        removeRemoteCommands()
        Task { [audioSessionController] in
            await audioSessionController.deactivate()
        }
    }

    func resetProgressTracking() {
        position = 0
        duration = 0
        automaticSourceRefreshAttempts = 0
        recoveryAttemptCount = 0
        recoveryBaselinePosition = 0
        playbackErrorMessage = nil
    }

    func prepareForForegroundResume() {
        Task { [audioSessionController] in
            await audioSessionController.activateForPlayback()
        }
    }

    func prepareForBackground() {
        // Keep the playback audio session alive while the PlayerScreen exists.
    }

    func retryPlayback() {
        guard currentSourceURL != nil else { return }
        playbackErrorMessage = nil
        automaticSourceRefreshAttempts = 0
        recoveryAttemptCount = 0
        sourceRefreshRequestedForURL = nil
        lastItemFailureAt = nil
        playbackWasRequested = true
        shouldResumeAfterBuffering = true
        isBuffering = true
        playbackState = .recovering
        requestSourceRefresh()
    }

    /// Snapshot the active item while it keeps playing. The replacement is
    /// prepared independently and is swapped in only after validation succeeds.
    func beginSourceSwitch() {
        guard let item = player.currentItem, pendingSourceSwitchItem == nil else { return }
        let time = player.currentTime().seconds
        pendingSourceSwitchTime = time.isFinite ? time : position
        pendingSourceSwitchShouldPlay = player.rate > 0 || player.timeControlStatus != .paused
        pendingSourceSwitchRate = player.rate > 0 ? player.rate : player.defaultRate
        pendingSourceSwitchItem = item
        isSourceSwitching = true
    }

    func supersedeSourceSwitch() {
        guard isSourceSwitching
                || pendingSourceSwitchItem != nil else {
            return
        }

        // Invalidate any replacement currently being prepared,
        // while deliberately keeping the original playback snapshot.
        sourceSwitchGeneration = UUID()
    }

    func cancelSourceSwitch(resumePrevious: Bool) {
        let shouldResume = resumePrevious && pendingSourceSwitchShouldPlay == true
        let rate = pendingSourceSwitchRate ?? player.defaultRate
        let previousItem = pendingSourceSwitchItem
        pendingSourceSwitchTime = nil
        pendingSourceSwitchShouldPlay = nil
        pendingSourceSwitchRate = nil
        pendingSourceSwitchItem = nil
        isSourceSwitching = false
        isPreparingPlayback = false
        if resumePrevious, player.currentItem == nil, let previousItem {
            player.replaceCurrentItem(with: previousItem)
        }
        isBuffering = false
        if shouldResume {
            player.playImmediately(atRate: rate)
        }
        // Always recompute chrome state — leaving `.preparing` after a failed
        // switch kept the "Loading video…" banner up over the error alert.
        refreshPlaybackState()
    }

    private func recordPlaybackRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        // Video content is dominated by dialogue. The time-domain processor
        // preserves pitch with substantially less work than the default
        // spectral processor, preventing its audio queue from falling behind
        // the shared player clock during sustained accelerated playback.
        player.currentItem?.audioTimePitchAlgorithm = .timeDomain
        let value = Double(rate)
        guard abs(playbackRate - value) > 0.001 else { return }
        playbackRate = value
    }

    /// Prepare using a separate subtitle server so a failed switch cannot delete
    /// the active stream's playlist or subtitle routes.
    func switchSource(_ stream: PlayableStream, externalSubtitles: [SubtitleSource],
                      quality: StreamQuality? = nil, useQualityChoice: Bool = false) async -> Bool {
        guard let oldItem = pendingSourceSwitchItem ?? player.currentItem else { return false }
        let previousPlaybackGeneration = playbackGeneration
        let previousAutomaticEnrichmentUsed = automaticEnrichmentUsed
        let previousAutomaticEnrichmentCount = automaticSubtitleEnrichmentCount
        let previousEnrichmentDeadline = backgroundEnrichmentDeadline
        let previousNativeDescriptors = nativeSubtitleDescriptors
        playbackGeneration = UUID()
        automaticEnrichmentUsed = false
        automaticSubtitleEnrichmentCount = 0
        backgroundEnrichmentTask?.cancel()
        backgroundEnrichmentTask = nil
        automaticEnrichmentTask?.cancel()
        automaticEnrichmentTask = nil
        automaticEnrichmentInProgressGeneration = nil
        backgroundEnrichmentDeadline = ContinuousClock().now.advanced(by: .seconds(15))
        nativeDescriptorTask?.cancel()
        nativeSubtitleDescriptors = []
        let generation = UUID()
        sourceSwitchGeneration = generation
        let oldServer = subtitleServer
        let oldNames = injectedSubtitleNames
        let oldLanguageTags = injectedSubtitleLanguageTags
        let oldRenditions = subtitleRenditions
        let oldByName = subtitleRenditionsByDisplayName
        let oldByID = subtitleRenditionsBySelectionID
        let oldTracks = subtitleStudioTracks
        let oldSubtitleSource = subtitlePlaybackSource
        let oldCanStudio = canOpenSubtitleStudio
        let oldCanAdjust = canAdjustSubtitleTiming
        let oldLanguage = primarySubtitleLanguage
        let subtitleID = await selectedSubtitleSelectionID()
        let subtitleName = await selectedSubtitleDisplayName()
        let selectedRendition = subtitleID.flatMap { oldByID[$0] }
            ?? subtitleName.flatMap { oldByName[$0] }
        let audible = try? await oldItem.asset.loadMediaSelectionGroup(for: .audible)
        let selectedAudioLanguage = audible.flatMap { oldItem.currentMediaSelection.selectedMediaOption(in: $0)?.extendedLanguageTag }
        let subtitlesWereOff = !subtitleUserRequestedOn
        guard generation == sourceSwitchGeneration, !Task.isCancelled else { return false }
        qualitySwitchTask?.cancel()
        subtitleAdjustmentTask?.cancel()
        let height = useQualityChoice ? quality?.height : preferredQualityHeight
        let newQuality = height.flatMap { StreamQuality.closest(to: $0, in: stream.qualities) }
        let source = stream.source.preferredForSubtitleLanguage(primarySubtitleLanguage)
        subtitleServer = HLSSubtitleLoopbackServer()
        let asset = await assetByInjectingSubtitles(
            source.subtitles + externalSubtitles,
            into: source,
            selectedQuality: newQuality,
            generation: generation,
            preparePreferredSubtitle: subtitleUserRequestedOn
        )
        let playable = await replacementIsReady(asset, generation: generation)
        let oldItemIsStillCurrent = player.currentItem === oldItem
        let oldItemIsDetachedForSwitch = player.currentItem == nil && pendingSourceSwitchItem === oldItem
        guard playable,
              generation == sourceSwitchGeneration,
              !Task.isCancelled,
              oldItemIsStillCurrent || oldItemIsDetachedForSwitch else {

            // A newer source-switch request superseded this one.
            // Do not restore state or clear the original playback snapshot,
            // because the newer request is still using it.
            guard generation == sourceSwitchGeneration else {
                return false
            }

            subtitleServer = oldServer
            injectedSubtitleNames = oldNames
            injectedSubtitleLanguageTags = oldLanguageTags
            subtitleRenditions = oldRenditions
            subtitleRenditionsByDisplayName = oldByName
            subtitleRenditionsBySelectionID = oldByID
            subtitleStudioTracks = oldTracks
            subtitlePlaybackSource = oldSubtitleSource
            canOpenSubtitleStudio = oldCanStudio
            canAdjustSubtitleTiming = oldCanAdjust
            playbackGeneration = previousPlaybackGeneration
            automaticEnrichmentUsed = previousAutomaticEnrichmentUsed
            automaticSubtitleEnrichmentCount = previousAutomaticEnrichmentCount
            backgroundEnrichmentDeadline = previousEnrichmentDeadline
            nativeSubtitleDescriptors = previousNativeDescriptors

            cancelSourceSwitch(
                resumePrevious: true
            )

            updateExternalSubtitles(currentExternalSubtitles)

            return false
        }
        let liveTime = oldItem.currentTime().seconds
        let isAutomaticRecovery = nextReplacementShouldPlay != nil
        let resumeAt = isAutomaticRecovery
            ? (pendingSourceSwitchTime ?? (liveTime.isFinite ? liveTime : position))
            : (oldItemIsStillCurrent && liveTime.isFinite
                ? liveTime
                : (pendingSourceSwitchTime ?? position))
        let shouldPlay = nextReplacementShouldPlay
            ?? pendingSourceSwitchShouldPlay
            ?? (oldItemIsStillCurrent
                ? Optional(player.rate > 0 || player.timeControlStatus != .paused)
                : nil)
            ?? playbackWasRequested
        nextReplacementShouldPlay = nil
        let rate: Float
        if isAutomaticRecovery {
            rate = pendingSourceSwitchRate ?? player.defaultRate
        } else {
            rate = pendingSourceSwitchRate
                ?? (oldItemIsStillCurrent && player.rate > 0 ? player.rate : player.defaultRate)
        }
        pendingSourceSwitchTime = nil
        pendingSourceSwitchShouldPlay = nil
        pendingSourceSwitchRate = nil
        pendingSourceSwitchItem = nil
        isSourceSwitching = false
        availableQualities = stream.qualities
        selectedQuality = newQuality
        if useQualityChoice { preferredQualityHeight = quality?.height; qualityPreferenceInitialized = true }
        currentPlaybackSource = source
        currentExternalSubtitles = source.subtitles + externalSubtitles
        currentSourceURL = source.url
        currentSourceExpiresAt = Self.expirationDate(in: source.url)
        sourceRefreshRequestedForURL = nil
        automaticPeakBitRate = source.preferredPeakBitRate
        let descriptorGeneration = playbackGeneration
        nativeDescriptorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let descriptors = await HLSNativeSubtitleLoader.descriptors(
                from: source,
                client: self.subtitleClient
            )
            guard self.playbackGeneration == descriptorGeneration else { return }
            self.nativeSubtitleDescriptors = descriptors
            self.canOpenSubtitleStudio = !descriptors.isEmpty || !self.subtitleStudioTracks.isEmpty
            if let contentID = self.currentContentID {
                await self.prepareRememberedNativeSyncIfNeeded(
                    descriptors: descriptors,
                    source: source,
                    contentID: contentID,
                    generation: descriptorGeneration
                )
            }
        }
        playbackErrorMessage = nil
        // The view model bounds retries per server; allow recovery on the new server.
        automaticSourceRefreshAttempts = 0
        recoveryAttemptCount = 0
        if let selectedAudioLanguage { audioLanguage = selectedAudioLanguage }
        if subtitlesWereOff { primarySubtitleLanguage = "" }
        let restoredSubtitleID = selectedRendition.flatMap { rendition in
            rendition.syncVersionID.flatMap(selectionID(forSyncVersionID:))
                ?? selectionID(forBaseSubtitleKey: rendition.subtitle.syncKey)
        } ?? subtitleID
        replaceCurrentItem(with: asset, resumeAt: resumeAt, shouldPlay: shouldPlay, playbackRate: rate,
                           preferredSubtitleDisplayName: subtitleName,
                           preferredSubtitleSelectionID: subtitlesWereOff ? "__subtitles_off__" : restoredSubtitleID)
        primarySubtitleLanguage = oldLanguage
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.nativeDescriptorTask?.value
            guard self.playbackGeneration == descriptorGeneration else { return }
            self.updateExternalSubtitles(self.currentExternalSubtitles)
        }
        withExtendedLifetime(oldServer) { }
        return true
    }

    private func replacementIsReady(_ asset: AVAsset, generation: UUID) async -> Bool {
        let item = AVPlayerItem(asset: asset)
        let preparationPlayer = AVPlayer(playerItem: item)
        preparationPlayer.isMuted = true
        defer { preparationPlayer.replaceCurrentItem(with: nil) }
        // Loading a manifest alone does not establish that the native player can
        // prepare its tracks. Keep the working item until the replacement is ready.
        for _ in 0..<160 {
            guard generation == sourceSwitchGeneration, !Task.isCancelled else { return false }
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            default: break
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return false
    }

    func setQuality(_ quality: StreamQuality?) {
        guard selectedQuality != quality else { return }
        preferredQualityHeight = quality?.height
        qualityPreferenceInitialized = true
        selectedQuality = quality
        guard let item = player.currentItem else { return }
        qualitySwitchTask?.cancel()
        applyQuality(to: item)
    }

    func adjustSubtitleTiming(by delta: Double) {
        guard canAdjustSubtitleTiming,
              let source = subtitlePlaybackSource,
              !subtitleRenditions.isEmpty else { return }
        let updatedOffset = min(
            10,
            max(-10, ((subtitleTimingOffset + delta) * 10).rounded() / 10)
        )
        guard updatedOffset != subtitleTimingOffset else { return }
        subtitleTimingOffset = updatedOffset
        subtitleAdjustmentTask?.cancel()
        let renditions = subtitleRenditions
        subtitleAdjustmentTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self else { return }
                let injectedAsset = try await HLSSubtitleInjector.prepare(
                    source: source,
                    renditions: renditions,
                    timingOffset: updatedOffset,
                    selectedQualityHeight: selectedQuality?.height,
                    primarySubtitleLanguage: primarySubtitleLanguage,
                    secondarySubtitleLanguage: secondarySubtitleLanguage,
                    client: subtitleClient
                )
                try Task.checkCancellation()
                let selectedSubtitleName = await self.selectedSubtitleDisplayName()
                let selectedSubtitleSelectionID = await self.selectedSubtitleSelectionID()
                let localMasterURL = try await self.subtitleServer.publish(injectedAsset)
                let currentTime = self.player.currentTime().seconds
                let resumeAt = currentTime.isFinite ? currentTime : self.position
                let wasPlaying = self.player.timeControlStatus != .paused
                let playbackRate = self.player.rate > 0
                    ? self.player.rate
                    : self.player.defaultRate
                self.injectedSubtitleNames = injectedAsset.displayNames
                self.injectedSubtitleLanguageTags = Set(
                    injectedAsset.languageTags.map { $0.lowercased() }
                )
                self.appliedSubtitleTimingOffset = updatedOffset
                self.replaceCurrentItem(
                    with: AVURLAsset(
                        url: localMasterURL,
                        options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
                    ),
                    resumeAt: resumeAt,
                    shouldPlay: wasPlaying,
                    playbackRate: playbackRate,
                    preferredSubtitleDisplayName: selectedSubtitleName,
                    preferredSubtitleSelectionID: selectedSubtitleSelectionID,
                    seekTolerance: .zero
                )
            } catch where error.isCancellation { }
            catch {
                guard let self else { return }
                self.subtitleTimingOffset = self.appliedSubtitleTimingOffset
            }
        }
    }

    func beginSubtitleStudio() async -> SubtitleStudioContext? {
        isSubtitleStudioSeeking = false
        isSubtitleStudioActive = true
        studioWasPlaying = player.timeControlStatus != .paused
        subtitleStudioPosition = player.currentTime().seconds.isFinite
            ? player.currentTime().seconds
            : position
        installStudioTimeObserver()
        await logSubtitleDiagnostics(at: subtitleStudioPosition)
        studioPreviousSubtitleDisplayName = await selectedSubtitleDisplayName()
        let selectedLanguageTag = await selectedSubtitleSelectionID()
        let selectedRendition = selectedLanguageTag.flatMap {
            subtitleRenditionsBySelectionID[$0]
        } ?? studioPreviousSubtitleDisplayName.flatMap {
            subtitleRenditionsByDisplayName[$0]
        }
        if selectedRendition == nil {
            await loadSelectedNativeStudioTrackIfNeeded(
                displayName: studioPreviousSubtitleDisplayName
            )
        }
        let selectedEmbeddedTrack = studioPreviousSubtitleDisplayName.flatMap { displayName in
            subtitleStudioTracks.first {
                $0.source.providerID == "native-hls" &&
                    ($0.source.label.localizedCaseInsensitiveCompare(displayName) == .orderedSame ||
                     $0.source.label.replacingOccurrences(of: " (Forced)", with: "")
                        .localizedCaseInsensitiveCompare(displayName) == .orderedSame)
            }
        }
        let selectedTrackID = selectedRendition?.subtitle.syncKey
            ?? selectedEmbeddedTrack?.id
            ?? subtitleStudioTracks.first?.id
        guard let selectedTrackID else {
            isSubtitleStudioActive = false
            return nil
        }
        let selectedTrack = subtitleStudioTracks.first { $0.id == selectedTrackID }
        let studioOffset = selectedRendition?.timingOffset ?? 0
        let sourceTime = subtitleStudioPosition - studioOffset
        let activeCue = selectedTrack?.cues.first {
            $0.startTime <= sourceTime && sourceTime < $0.endTime
        }
        SubtitleDiagnostics.logger.notice(
            "SUBSYNC studio: playerID=\(selectedLanguageTag ?? "none", privacy: .public) resolvedProvider=\(selectedTrack?.source.providerID ?? "none", privacy: .public) resolvedLabel=\(selectedTrack?.source.label ?? "none", privacy: .public) playerTime=\(self.subtitleStudioPosition, privacy: .public) offset=\(studioOffset, privacy: .public) cueStart=\(activeCue?.startTime ?? -1, privacy: .public) cueEnd=\(activeCue?.endTime ?? -1, privacy: .public)"
        )
        player.pause()
        await hideNativeSubtitlesForStudio()

        return SubtitleStudioContext(
            selectedTrackID: selectedTrackID,
            offset: selectedRendition?.timingOffset ?? 0,
            selectedVersionID: selectedRendition?.syncVersionID
        )
    }

    private func hideNativeSubtitlesForStudio() async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else {
            return
        }

        item.select(nil, in: group)
    }

    func cancelSubtitleStudio() async {
        isSubtitleStudioSeeking = false
        isSubtitleStudioActive = false
        await selectSubtitle(displayName: studioPreviousSubtitleDisplayName)
        if studioWasPlaying { player.play() }
        removeStudioTimeObserver()
        studioPreviousSubtitleDisplayName = nil
    }

    func applySubtitleSyncVersions(
        _ versions: [SubtitleSyncVersion],
        selecting versionID: UUID
    ) async {
        guard let source = subtitlePlaybackSource else {
            await cancelSubtitleStudio()
            return
        }
        subtitleSyncVersions = versions
        let resumeAt = player.currentTime().seconds.isFinite
            ? player.currentTime().seconds
            : position
        isBuffering = true
        let asset = await assetByInjectingSubtitles(
            currentExternalSubtitles,
            into: source,
            selectedQuality: selectedQuality
        )
        guard !Task.isCancelled else { return }
        replaceCurrentItem(
            with: asset,
            resumeAt: resumeAt,
            shouldPlay: studioWasPlaying,
            playbackRate: player.defaultRate,
            preferredSubtitleSelectionID: selectionID(forSyncVersionID: versionID),
            seekTolerance: .zero
        )
        isSubtitleStudioActive = false
        isSubtitleStudioSeeking = false
        removeStudioTimeObserver()
        studioPreviousSubtitleDisplayName = nil
    }

    private func loadSelectedNativeStudioTrackIfNeeded(displayName: String?) async {
        await nativeDescriptorTask?.value
        guard let source = currentPlaybackSource else { return }
        let cleanedDisplayName = displayName?
            .replacingOccurrences(of: " (Forced)", with: "")
        let descriptor = nativeSubtitleDescriptors.first { descriptor in
            descriptor.name.localizedCaseInsensitiveCompare(cleanedDisplayName ?? "") == .orderedSame
                || descriptor.subtitleSource.label.localizedCaseInsensitiveCompare(displayName ?? "") == .orderedSame
        } ?? nativeSubtitleDescriptors.first(where: \.isDefault)
        guard let descriptor,
              !subtitleStudioTracks.contains(where: {
                  $0.source.matchesSyncKey(descriptor.subtitleSource.syncKey)
              }) else { return }
        guard let rendition = await HLSNativeSubtitleLoader.load(
            descriptor: descriptor,
            from: source,
            client: subtitleClient
        ) else { return }
        if let currentContentID {
            await subtitleCache.store(rendition: rendition, contentID: currentContentID)
        }
        subtitleStudioTracks.append(
            SubtitleStudioTrack(source: rendition.subtitle, cues: rendition.cues)
        )
        canOpenSubtitleStudio = true
        subtitlePlaybackSource = source
    }

    func seek(to seconds: Double) {
        let safeDuration = duration.isFinite ? duration : 0
        let target = min(max(seconds, 0), max(safeDuration, 0))
        let token = UUID()
        subtitleStudioSeekToken = token
        isSubtitleStudioSeeking = true
        player.currentItem?.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.subtitleStudioSeekToken == token else { return }

                await self.hideNativeSubtitlesForStudio()
                self.isSubtitleStudioSeeking = false
            }
        }

        subtitleStudioPosition = target
    }

    func toggleStudioPlayback() {
        if player.timeControlStatus == .paused {
            Task {
                await hideNativeSubtitlesForStudio()
                player.play()
            }
        } else {
            player.pause()
        }
    }

    private func installStudioTimeObserver() {
        removeStudioTimeObserver()
        studioTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 10),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.subtitleStudioPosition = time.seconds.isFinite ? time.seconds : 0
            }
        }
    }

    private func removeStudioTimeObserver() {
        guard let studioTimeObserver else { return }
        player.removeTimeObserver(studioTimeObserver)
        self.studioTimeObserver = nil
    }

    private func assetByInjectingSubtitles(
        _ subtitles: [SubtitleSource],
        into source: PlaybackSource,
        selectedQuality: StreamQuality?,
        generation: UUID? = nil,
        contentID: String? = nil,
        loadingMode: SubtitleLoadingMode? = nil,
        preparedRenditions: [HLSSubtitleRendition]? = nil,
        preparePreferredSubtitle: Bool = true
    ) async -> AVURLAsset {
        let injectionPerfStart =
            PlaybackStartupTrace.now()

        PlaybackStartupTrace.mark(
            "subtitle asset START subtitles=\(subtitles.count)"
        )
        let originalAsset = AVURLAsset(
            url: source.url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
        )
        var seenResources: Set<String> = []
        let uniqueSubtitles = subtitles.filter { subtitle in
            subtitle.providerID != "native-hls" && seenResources.insert(subtitle.syncKey).inserted
        }
        let subtitleDownloadsStart =
            PlaybackStartupTrace.now()
        let resolvedContentID = contentID ?? currentContentID
        let resolvedMode = loadingMode ?? currentSubtitleLoadingMode
        let preparationDeadline = preparedRenditions == nil
            ? ContinuousClock().now.advanced(
                by: resolvedMode == .fast ? .seconds(5) : .seconds(15)
            )
            : backgroundEnrichmentDeadline
        let loadedRenditions: [HLSSubtitleRendition]
        if let preparedRenditions {
            loadedRenditions = sortSubtitleRenditions(preparedRenditions)
        } else if let resolvedContentID {
            let cachedEntries = await sourceCorrectCachedEntries(
                contentID: resolvedContentID,
                source: source
            )
            let cached = cachedEntries.map(\.rendition)
            let freshKeys = Set(
                cachedEntries
                    .filter { $0.status == .fresh }
                    .map { $0.rendition.subtitle.syncKey }
            )
            // A stale rendition is playable immediately, but route its live
            // source through the cache actor so one background refresh starts.
            let uncached = uniqueSubtitles.filter { !freshKeys.contains($0.syncKey) }
            let requested: [SubtitleSource]
            switch resolvedMode {
            case .fast:
                requested = preparePreferredSubtitle
                    ? preferredExternalSubtitle(in: uncached).map { [$0] } ?? []
                    : []
            case .completeBeforePlayback:
                requested = preparePreferredSubtitle ? uncached : []
            }
            let downloaded = await loadSubtitleRenditions(
                requested,
                contentID: resolvedContentID,
                deadline: preparationDeadline ?? ContinuousClock().now,
                perTrackBudget: resolvedMode == .fast ? .seconds(5) : .seconds(10)
            )
            var byKey = Dictionary(uniqueKeysWithValues: cached.map {
                ($0.subtitle.syncKey, $0)
            })
            for rendition in downloaded {
                byKey[rendition.subtitle.syncKey] = rendition
            }
            loadedRenditions = sortSubtitleRenditions(Array(byKey.values))
        } else {
            loadedRenditions = []
        }
        PlaybackStartupTrace.mark(
            "SUBTITLE PERF preferred track READY total=\(loadedRenditions.count) duration=\(PlaybackStartupTrace.duration(since: subtitleDownloadsStart))ms"
        )
        guard !Task.isCancelled, generation == nil || generation == sourceSwitchGeneration else { return originalAsset }
        subtitleStudioTracks = loadedRenditions.map {
            SubtitleStudioTrack(source: $0.subtitle, cues: $0.cues)
        }
        canOpenSubtitleStudio = !subtitleStudioTracks.isEmpty
        subtitlePlaybackSource = loadedRenditions.isEmpty ? nil : source
        let renditions = expandedSubtitleRenditions(from: loadedRenditions)
        guard !renditions.isEmpty else { return originalAsset }
        if let preparationDeadline,
           ContinuousClock().now >= preparationDeadline {
            SubtitleDiagnostics.logger.info("SUBTITLE PERF startup budget EXPIRED before injection")
            return originalAsset
        }

        do {
            let injectorStart =
                PlaybackStartupTrace.now()
            let injectedAsset = try await HLSSubtitleInjector.prepare(
                source: source,
                renditions: renditions,
                timingOffset: appliedSubtitleTimingOffset,
                selectedQualityHeight: selectedQuality?.height,
                primarySubtitleLanguage: primarySubtitleLanguage,
                secondarySubtitleLanguage: secondarySubtitleLanguage,
                client: subtitleClient,
                deadline: preparationDeadline
            )
            PlaybackStartupTrace.mark(
                "subtitle injector PREPARED duration=\(PlaybackStartupTrace.duration(since: injectorStart))ms"
            )
            try Task.checkCancellation()
            let publishStart =
                PlaybackStartupTrace.now()
            let localMasterURL = try await subtitleServer.publish(injectedAsset)
            PlaybackStartupTrace.mark(
                "subtitle server PUBLISHED duration=\(PlaybackStartupTrace.duration(since: publishStart))ms"
            )
            try Task.checkCancellation()
            guard generation == nil || generation == sourceSwitchGeneration else { return originalAsset }
            injectedSubtitleNames = injectedAsset.displayNames
            injectedSubtitleLanguageTags = Set(
                injectedAsset.languageTags.map { $0.lowercased() }
            )
            subtitleRenditions = renditions
            subtitleRenditionsByDisplayName = Dictionary(
                uniqueKeysWithValues: zip(injectedAsset.orderedDisplayNames, renditions)
            )
            subtitleRenditionsBySelectionID = SubtitleSelectionLookup.make(
                displayNames: injectedAsset.orderedDisplayNames,
                languageTags: injectedAsset.orderedLanguageTags,
                renditions: renditions
            )
            for (index, rendition) in renditions.enumerated() {
                let languageTag = injectedAsset.orderedLanguageTags[index]
                SubtitleDiagnostics.logger.notice(
                    "SUBSYNC generated: tag=\(languageTag, privacy: .public) provider=\(rendition.subtitle.providerID, privacy: .public) label=\(rendition.subtitle.label, privacy: .public) offset=\(rendition.timingOffset, privacy: .public) cues=\(rendition.cues.count, privacy: .public)"
                )
            }
            subtitlePlaybackSource = loadedRenditions.isEmpty ? nil : source
            PlaybackStartupTrace.mark(
                "subtitle asset DONE total=\(PlaybackStartupTrace.duration(since: injectionPerfStart))ms"
            )
            return AVURLAsset(
                url: localMasterURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers]
            )
        } catch where error.isCancellation {
            return originalAsset
        } catch {
            guard generation == nil || generation == sourceSwitchGeneration else { return originalAsset }
            injectedSubtitleNames = []
            injectedSubtitleLanguageTags = []
            subtitleRenditions = []
            subtitleRenditionsByDisplayName = [:]
            subtitleRenditionsBySelectionID = [:]
            subtitleStudioTracks = []
            canOpenSubtitleStudio = false
            subtitlePlaybackSource = nil
            canAdjustSubtitleTiming = false
            subtitleServer.clear()
            return originalAsset
        }
    }

    private func sortSubtitleRenditions(
        _ renditions: [HLSSubtitleRendition]
    ) -> [HLSSubtitleRendition] {
        let primary = SubtitleLanguage.canonicalCode(primarySubtitleLanguage)
        let secondary = SubtitleLanguage.canonicalCode(secondarySubtitleLanguage)

        return renditions.enumerated().sorted { lhs, rhs in
            let left = lhs.element.subtitle
            let right = rhs.element.subtitle

            let leftKey = subtitleSortKey(
                for: left,
                primary: primary,
                secondary: secondary
            )

            let rightKey = subtitleSortKey(
                for: right,
                primary: primary,
                secondary: secondary
            )

            if leftKey.group != rightKey.group {
                return leftKey.group < rightKey.group
            }

            if leftKey.language != rightKey.language {
                return leftKey.language.localizedCaseInsensitiveCompare(
                    rightKey.language
                ) == .orderedAscending
            }

            if leftKey.source != rightKey.source {
                return leftKey.source < rightKey.source
            }

            let providerComparison =
                left.providerName.localizedCaseInsensitiveCompare(
                    right.providerName
                )

            if providerComparison != .orderedSame {
                return providerComparison == .orderedAscending
            }

            let labelComparison =
                left.label.localizedCaseInsensitiveCompare(
                    right.label
                )

            if labelComparison != .orderedSame {
                return labelComparison == .orderedAscending
            }

            // Final stable fallback: preserve the original order.
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private func subtitleSortKey(
        for subtitle: SubtitleSource,
        primary: String?,
        secondary: String?
    ) -> (
        group: Int,
        language: String,
        source: Int
    ) {
        let languageCode = subtitle.canonicalLanguageCode

        let languageName = SubtitleLanguage.displayName(
            languageCode
        )

        let isBuiltIn =
            subtitle.providerID == "native-hls"
            || subtitle.providerID == "stream"

        let sourceOrder = isBuiltIn ? 0 : 1

        if let primary,
           languageCode == primary {
            return (
                group: 0,
                language: languageName,
                source: sourceOrder
            )
        }

        if let secondary,
           languageCode == secondary {
            return (
                group: 1,
                language: languageName,
                source: sourceOrder
            )
        }

        if isBuiltIn {
            return (
                group: 2,
                language: languageName,
                source: 0
            )
        }

        return (
            group: 3,
            language: languageName,
            source: 1
        )
    }

    private func expandedSubtitleRenditions(
        from baseRenditions: [HLSSubtitleRendition]
    ) -> [HLSSubtitleRendition] {
        baseRenditions.flatMap { rendition in
            let saved = subtitleSyncVersions
                .filter { rendition.subtitle.matchesSyncKey($0.subtitleKey) }
                .sorted { $0.createdAt < $1.createdAt }
                .enumerated()
                .map { index, version in
                    HLSSubtitleRendition(
                        subtitle: rendition.subtitle,
                        cues: rendition.cues,
                        timingOffset: version.offset,
                        syncVersionID: version.id,
                        displayNameOverride: rendition.subtitle.resyncDisplayName(
                            offset: version.offset
                        )
                    )
                }
            return (rendition.subtitle.providerID == "native-hls" ? [] : [rendition]) + saved
        }
    }

    private func selectionID(forSyncVersionID id: UUID) -> String? {
        subtitleRenditionsByDisplayName.first { $0.value.syncVersionID == id }?.key
    }

    private func selectionID(forBaseSubtitleKey key: String) -> String? {
        subtitleRenditionsByDisplayName.first {
            $0.value.syncVersionID == nil && $0.value.subtitle.matchesSyncKey(key)
        }?.key
    }

    private func preferredExternalSubtitle(in subtitles: [SubtitleSource]) -> SubtitleSource? {
        if let rememberedSubtitleSelection,
           let remembered = subtitles.first(where: {
               $0.matchesSyncKey(rememberedSubtitleSelection.baseSubtitleKey)
           }) {
            return remembered
        }
        if let primary = SubtitleSource.firstAlphabetically(
            matching: primarySubtitleLanguage,
            in: subtitles
        ) {
            return primary
        }
        return SubtitleSource.firstAlphabetically(
            matching: secondarySubtitleLanguage,
            in: subtitles
        ) ?? subtitles.first(where: \.isDefault) ?? subtitles.first
    }

    private func sourceCorrectCachedRenditions(
        contentID: String,
        source: PlaybackSource
    ) async -> [HLSSubtitleRendition] {
        await sourceCorrectCachedEntries(
            contentID: contentID,
            source: source
        ).map(\.rendition)
    }

    private func sourceCorrectCachedEntries(
        contentID: String,
        source: PlaybackSource
    ) async -> [CachedSubtitleRendition] {
        let cached = await subtitleCache.cachedRenditions(for: contentID)
        let currentNativeKeys = Set(nativeSubtitleDescriptors.map(\.subtitleSource.syncKey))
        let currentSourceKeys = Set(source.subtitles.map(\.syncKey))
        let contentProviderIDs = SubtitleProviderPreferences.contentProviderIDs
        return cached.filter { entry in
            let subtitle = entry.rendition.subtitle
            if subtitle.providerID == "native-hls" {
                return currentNativeKeys.contains(where: subtitle.matchesSyncKey)
            }
            return contentProviderIDs.contains(subtitle.providerID)
                || currentSourceKeys.contains(where: subtitle.matchesSyncKey)
        }
    }

    private func prepareRememberedNativeSyncIfNeeded(
        descriptors: [NativeHLSSubtitleDescriptor],
        source: PlaybackSource,
        contentID: String,
        generation: UUID
    ) async {
        guard let rememberedSubtitleSelection else { return }
        let exactVersion = rememberedSubtitleSelection.syncVersionID.flatMap { id in
            subtitleSyncVersions.first { $0.id == id }
        }
        let latestVersion = automaticallySelectLatestSubtitleSync
            ? subtitleSyncVersions
                .filter { $0.subtitleKey == rememberedSubtitleSelection.baseSubtitleKey }
                .max { $0.createdAt < $1.createdAt }
            : nil
        guard let version = exactVersion ?? latestVersion,
              let descriptor = descriptors.first(where: {
                  $0.subtitleSource.matchesSyncKey(version.subtitleKey)
                    || $0.subtitleSource.matchesSyncKey(rememberedSubtitleSelection.baseSubtitleKey)
              }),
              playbackGeneration == generation,
              !Task.isCancelled else { return }

        let client = subtitleClient
        let rendition: HLSSubtitleRendition
        do {
            rendition = try await subtitleCache.rendition(
                contentID: contentID,
                subtitle: descriptor.subtitleSource
            ) {
                guard let loaded = await HLSNativeSubtitleLoader.load(
                    descriptor: descriptor,
                    from: source,
                    client: client
                ) else { throw AppError.noStream }
                return loaded.cues
            }
        } catch {
            return
        }
        guard playbackGeneration == generation, !Task.isCancelled else { return }
        if !subtitleStudioTracks.contains(where: {
            $0.source.matchesSyncKey(rendition.subtitle.syncKey)
        }) {
            subtitleStudioTracks.append(
                SubtitleStudioTrack(source: rendition.subtitle, cues: rendition.cues)
            )
        }
        subtitlePlaybackSource = source
        canOpenSubtitleStudio = true
    }

    private func selectSubtitle(displayName: String?) async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return }
        var selection: AVMediaSelectionOption?
        if let displayName {
            for option in group.options where await subtitleSelectionID(option) == displayName {
                selection = option
                break
            }
        }
        item.select(selection, in: group)
        applySubtitleAppearance(to: item)
        await refreshSubtitlePickerEntries()
    }

    func refreshSubtitlePickerEntries() async {
        let selectedID = await selectedSubtitleSelectionID()
        let selectedDisplay = await selectedSubtitleDisplayName()
        let subtitlesOff = selectedID == nil && selectedDisplay == nil
        var entries: [SubtitlePickerEntry] = [.off(isSelected: subtitlesOff)]

        var seenSyncKeys = Set<String>()
        let rankedTracks = subtitleStudioTracks.sorted {
            SubtitleRanking.compare(
                $0.source,
                $1.source,
                primary: SubtitleLanguage.canonicalCode(primarySubtitleLanguage),
                secondary: SubtitleLanguage.canonicalCode(secondarySubtitleLanguage)
            )
        }

        for track in rankedTracks {
            guard seenSyncKeys.insert(track.source.syncKey).inserted else { continue }
            let selectionID = subtitleRenditions.first {
                $0.subtitle.syncKey == track.source.syncKey
            }.flatMap { rendition in
                subtitleRenditionsBySelectionID.first { $0.value.subtitle.syncKey == rendition.subtitle.syncKey }?.key
            }
            let displayMatch = selectedDisplay.map {
                track.source.label.localizedCaseInsensitiveCompare($0) == .orderedSame
                    || track.displayName.localizedCaseInsensitiveCompare($0) == .orderedSame
            } ?? false
            let selectionMatch = selectionID.map { $0 == selectedID } ?? false
            let syncMatch = selectedID.flatMap { subtitleRenditionsBySelectionID[$0]?.subtitle.syncKey } == track.source.syncKey
            let isSelected = !subtitlesOff && (selectionMatch || displayMatch || syncMatch)
            let isSynced = subtitleRenditions.contains {
                $0.subtitle.syncKey == track.source.syncKey && $0.syncVersionID != nil
            }
            let language = SubtitleLanguage.displayName(track.source.languageCode)
            entries.append(
                SubtitlePickerEntry(
                    id: track.source.syncKey,
                    kind: .track,
                    title: language,
                    subtitle: "\(track.source.providerName) · \(track.source.label)",
                    providerName: track.source.providerName,
                    languageCode: track.source.canonicalLanguageCode,
                    isSelected: isSelected,
                    isSynced: isSynced,
                    syncKey: track.source.syncKey
                )
            )
        }

        subtitlePickerEntries = entries
    }

    func selectSubtitlePickerEntry(_ entry: SubtitlePickerEntry) async {
        subtitleSelectionAuthority.recordExplicitUserSelection()
        switch entry.kind {
        case .off:
            subtitleUserRequestedOn = false
            await selectSubtitle(displayName: nil)
            onSubtitleVisibilityChanged?(false)
            onSubtitleSelectionChanged?(
                SubtitleSelectionPreference(baseSubtitleKey: "__subtitles_off__", syncVersionID: nil)
            )
        case .track:
            subtitleUserRequestedOn = true
            onSubtitleVisibilityChanged?(true)
            if let syncKey = entry.syncKey,
               let selectionID = subtitleRenditionsBySelectionID.first(where: {
                   $0.value.subtitle.syncKey == syncKey
               })?.key {
                await selectSubtitle(displayName: selectionID)
                if let rendition = subtitleRenditionsBySelectionID[selectionID] {
                    onSubtitleSelectionChanged?(
                        SubtitleSelectionPreference(
                            baseSubtitleKey: rendition.subtitle.syncKey,
                            syncVersionID: rendition.syncVersionID
                        )
                    )
                }
            } else if let syncKey = entry.syncKey,
                      let track = subtitleStudioTracks.first(where: { $0.source.syncKey == syncKey }) {
                await selectSubtitle(displayName: track.source.label)
                onSubtitleSelectionChanged?(
                    SubtitleSelectionPreference(baseSubtitleKey: track.source.syncKey, syncVersionID: nil)
                )
            }
        }
        await refreshSubtitlePickerEntries()
    }

    func applySubtitleAppearance(to item: AVPlayerItem? = nil) {
        let target = item ?? player.currentItem
        target?.textStyleRules = SubtitleAppearancePreferences.textStyleRules()
    }

    private func loadSubtitleRenditions(
        _ subtitles: [SubtitleSource],
        contentID: String,
        deadline: ContinuousClock.Instant,
        perTrackBudget: Duration,
        onReady: (@MainActor (HLSSubtitleRendition) -> Void)? = nil
    ) async -> [HLSSubtitleRendition] {
        let client = subtitleClient
        let cache = subtitleCache
        let maximumConcurrentDownloads = 6

        guard !subtitles.isEmpty else {
            return []
        }

        return await withTaskGroup(
            of: (Int, HLSSubtitleRendition?).self,
            returning: [HLSSubtitleRendition].self
        ) { group in
            var loaded: [(Int, HLSSubtitleRendition)] = []

            let initialCount = min(
                maximumConcurrentDownloads,
                subtitles.count
            )

            func addTask(
                index: Int,
                subtitle: SubtitleSource
            ) {
                group.addTask {
                    do {
                        let clock = ContinuousClock()
                        let trackDeadline = min(
                            deadline,
                            clock.now.advanced(by: perTrackBudget)
                        )
                        let rendition = try await cache.rendition(
                            contentID: contentID,
                            subtitle: subtitle
                        ) {
                            var request = URLRequest(url: subtitle.url)
                            for (name, value) in subtitle.headers {
                                request.setValue(value, forHTTPHeaderField: name)
                            }
                            request.setValue(
                                "text/plain,text/vtt,application/x-subrip,*/*;q=0.8",
                                forHTTPHeaderField: "Accept"
                            )
                            request.setValue(
                                HTTPClient.desktopUserAgent,
                                forHTTPHeaderField: "User-Agent"
                            )
                            let response = try await SubtitleResourceRetry.load(
                                request: request,
                                client: client,
                                deadline: trackDeadline
                            )
                            try Task.checkCancellation()
                            let parsed = try SubtitleParser.cues(
                                from: response.data,
                                languageCode: subtitle.languageCode
                            )
                            return SubtitleDirectionFormatter.normalizedCues(
                                parsed,
                                languageCode: subtitle.languageCode
                            )
                        }
                        return (
                            index,
                            rendition
                        )
                    } catch {
                        return (
                            index,
                            nil
                        )
                    }
                }
            }

            for index in 0..<initialCount {
                addTask(
                    index: index,
                    subtitle: subtitles[index]
                )
            }

            var nextIndex = initialCount

            while let (
                index,
                rendition
            ) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return []
                }

                if let rendition {
                    loaded.append(
                        (index, rendition)
                    )
                    onReady?(rendition)
                }

                if nextIndex < subtitles.count {
                    addTask(
                        index: nextIndex,
                        subtitle: subtitles[nextIndex]
                    )

                    nextIndex += 1
                }
            }

            return loaded
                .sorted {
                    $0.0 < $1.0
                }
                .map(\.1)
        }
    }
    private func replaceCurrentItem(
        with asset: AVURLAsset,
        resumeAt: Double,
        shouldPlay: Bool,
        playbackRate: Float,
        preferredSubtitleDisplayName: String? = nil,
        preferredSubtitleSelectionID: String? = nil,
        seekTolerance: CMTime = PlaybackSeekPolicy.normalTolerance
    ) {
        mediaOptionsTask?.cancel()
        let mediaSelectionGeneration = UUID()
        self.mediaSelectionGeneration = mediaSelectionGeneration
        subtitleSelectionAuthority.beginPlayerItem()
        subtitleVisibilityObservation.beginPlayerItem()
        isStabilizingMediaSelection = true
        playbackWasRequested = shouldPlay
        shouldResumeAfterBuffering = false
        // Keep playback behind the media-selection gate. AVPlayer can otherwise
        // begin rendering before its asynchronously loaded subtitle group has
        // received the saved/default selection.
        isPreparingPlayback = shouldPlay
        if isPreparingPlayback { isBuffering = true }
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain
        applyQuality(to: item)
        observeBufferingState(
            of: item,
            preferredSubtitleDisplayName: preferredSubtitleDisplayName,
            preferredSubtitleSelectionID: preferredSubtitleSelectionID
        )
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let mediaSelectionObserver { NotificationCenter.default.removeObserver(mediaSelectionObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEnded?() }
        }
        mediaSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item else { return }
                self.refreshSubtitleTimingAvailability(for: item)
                self.recordSubtitleVisibilityChange(for: item)
                if !self.isStabilizingMediaSelection {
                    self.subtitleSelectionAuthority.recordExplicitUserSelection()
                    Task { @MainActor [weak self, weak item] in
                        guard let self, let item else { return }
                        await self.recordSelectedSubtitlePreference(from: item)
                    }
                }
            }
        }
        player.replaceCurrentItem(with: item)
        if !shouldPlay {
            // AVPlayer can carry a pending play intent across item replacement
            // even when the outgoing item was paused. Reassert the captured
            // user intent immediately and again after the preparation seek.
            player.pause()
        }
        let preparationControlRevision = player.controlSnapshot.revision
        player.defaultRate = playbackRate
        mediaOptionsTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            defer {
                if self.mediaSelectionGeneration == mediaSelectionGeneration {
                    self.isStabilizingMediaSelection = false
                    self.mediaOptionsTask = nil
                }
            }
            guard await self.waitUntilReadyForMediaSelection(item),
                  !Task.isCancelled,
                  self.mediaSelectionGeneration == mediaSelectionGeneration,
                  self.player.currentItem === item else { return }
            await self.applyPreferredLanguages(
                to: asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleSelectionID: preferredSubtitleSelectionID
            )
            // Some HLS manifests publish a forced/default rendition as the item
            // settles. AVPlayer can momentarily restore that choice even with
            // automatic criteria disabled, so reassert our explicit selection
            // after the initial media-selection notification cycle.
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return
            }
            await self.applyPreferredLanguages(
                to: asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleSelectionID: preferredSubtitleSelectionID
            )
            guard !Task.isCancelled,
                  self.mediaSelectionGeneration == mediaSelectionGeneration,
                  self.player.currentItem === item else { return }

            var seekFinished = true
            if resumeAt > 0 {
                seekFinished = await item.seek(
                    to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                    toleranceBefore: seekTolerance,
                    toleranceAfter: seekTolerance
                )
            }
            // Seeking can cause another HLS rendition reconciliation. Selection
            // must be the last preparation step before playback is released.
            await self.applyPreferredLanguages(
                to: asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleSelectionID: preferredSubtitleSelectionID
            )
            guard !Task.isCancelled,
                  self.mediaSelectionGeneration == mediaSelectionGeneration,
                  self.player.currentItem === item else { return }
            self.isPreparingPlayback = false
            let latestControl = self.player.controlSnapshot
            let finalShouldPlay = latestControl.revision == preparationControlRevision
                ? shouldPlay
                : latestControl.shouldPlay ?? shouldPlay
            guard seekFinished, finalShouldPlay else {
                if !finalShouldPlay { self.player.pause() }
                self.refreshPlaybackState()
                return
            }
            // `play()` deliberately uses `defaultRate`, retaining AVPlayer's
            // automatic wait-for-buffer behavior.
            self.player.play()
            // AVPlayer can re-apply a manifest's forced/default subtitle shortly after
            // playback begins. Reassert BetterStreamflix's preferred selection a few times while the
            // item settles so late HLS reconciliation cannot leave a forced subtitle active.
            for delay in [250, 500, 1000] {
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      self.mediaSelectionGeneration == mediaSelectionGeneration,
                      self.player.currentItem === item,
                      self.subtitleSelectionAuthority.allowsAutomaticSelection else {
                    return
                }

                await self.applyPreferredLanguages(
                    to: asset,
                    primarySubtitleLanguage: self.primarySubtitleLanguage,
                    secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                    audioLanguage: self.audioLanguage,
                    preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                    preferredSubtitleSelectionID: preferredSubtitleSelectionID
                )
            }
        }
    }

    private func waitUntilReadyForMediaSelection(_ item: AVPlayerItem) async -> Bool {
        while !Task.isCancelled, player.currentItem === item {
            switch item.status {
            case .readyToPlay:
                return true
            case .failed:
                return false
            default:
                do {
                    try await Task.sleep(for: .milliseconds(25))
                } catch {
                    return false
                }
            }
        }
        return false
    }

    private func observeBufferingState(
        of item: AVPlayerItem,
        preferredSubtitleDisplayName: String?,
        preferredSubtitleSelectionID: String?
    ) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) {
            [weak self, weak item] _, change in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                switch change.newValue {
                case .readyToPlay:
                    self.reapplyPreferredLanguagesIfNeeded(
                        to: item,
                        preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                        preferredSubtitleSelectionID: preferredSubtitleSelectionID
                    )
                case .failed:
                    self.handleItemFailure()
                default:
                    break
                }
            }
        }
        playbackBufferEmptyObservation = item.observe(
            \.isPlaybackBufferEmpty,
            options: [.initial, .new]
        ) { [weak self, weak item] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                guard self.playbackWasRequested
                        || self.player.timeControlStatus != .paused else { return }
                self.beginAutomaticBufferRecovery()
            }
        }
        playbackLikelyToKeepUpObservation = item.observe(
            \.isPlaybackLikelyToKeepUp,
            options: [.initial, .new]
        ) { [weak self, weak item] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                self.resumeWhenBufferIsReady()
            }
        }

        if let playbackStalledObserver {
            NotificationCenter.default.removeObserver(playbackStalledObserver)
        }
        playbackStalledObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.beginAutomaticBufferRecovery()
            }
        }
        if let playbackErrorLogObserver {
            NotificationCenter.default.removeObserver(playbackErrorLogObserver)
        }
        playbackErrorLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item,
                      let statusCode = item.errorLog()?.events.last?.errorStatusCode,
                      statusCode >= 400 else { return }
                self.handleItemFailure()
            }
        }
        if let failedToPlayToEndObserver {
            NotificationCenter.default.removeObserver(failedToPlayToEndObserver)
        }
        failedToPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.handleItemFailure()
            }
        }
        if let timeJumpedObserver {
            NotificationCenter.default.removeObserver(timeJumpedObserver)
        }
        timeJumpedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemTimeJumped,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item else { return }
                self.beginSeekRecoveryGrace()
                self.refreshPlaybackState()
            }
        }
    }

    private func refreshPlaybackState() {
        if isSourceSwitching {
            playbackState = .preparing
            isBuffering = true
            publishNowPlayingInfo()
            return
        }
        switch player.timeControlStatus {
        case .playing:
            playbackState = .playing
            playbackWasRequested = true
            shouldResumeAfterBuffering = false
            needsSourceRefreshAfterBackground = false
            isBuffering = false
            stagnantBufferChecks = 0
            recoveryWatchdogTask?.cancel()
            recoveryWatchdogTask = nil
        case .waitingToPlayAtSpecifiedRate:
            playbackState = isSeekRecoveryGraceActive ? .seeking : .buffering
            playbackWasRequested = true
            scheduleRecoveryWatchdogIfNeeded()
        case .paused:
            if isPreparingPlayback {
                playbackState = .preparing
                playbackWasRequested = true
                isBuffering = true
                publishNowPlayingInfo()
                return
            }
            playbackWasRequested = false
            shouldResumeAfterBuffering = false
            isBuffering = false
            playbackState = .paused
            recoveryWatchdogTask?.cancel()
            recoveryWatchdogTask = nil
            if player.currentItem?.status == .failed {
                requestSourceRefresh()
            }
        @unknown default:
            break
        }
        isBuffering = shouldResumeAfterBuffering
            || isPreparingPlayback
            || (playbackWasRequested
                && player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        publishNowPlayingInfo()
    }

    private func beginAutomaticBufferRecovery() {
        // Initial preparation intentionally keeps the item paused until subtitle
        // and audio selection has completed. An initial empty-buffer callback is
        // not a playback stall and must not bypass that gate.
        guard !isPreparingPlayback else { return }
        playbackWasRequested = true
        shouldResumeAfterBuffering = true
        playbackState = isSeekRecoveryGraceActive ? .seeking : .buffering
        isBuffering = true
        publishNowPlayingInfo()
        // A stall can leave AVPlayer in .paused rather than .waiting. Calling
        // play again preserves the user's play intent and keeps media loading.
        player.play()
        if needsSourceRefreshAfterBackground {
            requestSourceRefresh()
        } else {
            refreshSourceIfExpired()
        }
        scheduleRecoveryWatchdogIfNeeded()
    }

    private func resumeWhenBufferIsReady() {
        guard !isPreparingPlayback else { return }
        guard playbackWasRequested || shouldResumeAfterBuffering else { return }
        player.play()
    }

    private func refreshSourceIfExpired() {
        guard sourceIsExpiredOrExpiringSoon else { return }
        requestSourceRefresh()
    }

    private var sourceIsExpiredOrExpiringSoon: Bool {
        currentSourceExpiresAt.map { $0 <= Date().addingTimeInterval(30) } ?? false
    }

    private func schedulePausedSourceRefreshBeforeExpiration() {
        sourceExpirationTask?.cancel()
        guard let currentSourceURL, let currentSourceExpiresAt else { return }
        let delay = max(0, currentSourceExpiresAt.timeIntervalSinceNow - 30)
        sourceExpirationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  self.currentSourceURL == currentSourceURL,
                  self.currentSourceExpiresAt == currentSourceExpiresAt,
                  self.player.timeControlStatus == .paused,
                  !self.playbackWasRequested,
                  !self.isPreparingPlayback else { return }
            self.requestSourceRefresh()
        }
    }

    private func requestSourceRefresh() {
        guard let currentSourceURL,
              sourceRefreshRequestedForURL != currentSourceURL,
              sourceRefreshTask == nil else { return }
        guard automaticSourceRefreshAttempts < PlaybackRecoveryPolicy.maximumSourceRefreshes else {
            failPlaybackRecovery()
            return
        }
        guard let onSourceRefreshNeeded else {
            failPlaybackRecovery()
            return
        }
        sourceRefreshRequestedForURL = currentSourceURL
        playbackState = .recovering
        let currentTime = player.currentTime().seconds
        let recovery = playbackSeekState.recoverySnapshot(
            currentPosition: currentTime.isFinite ? currentTime : position,
            fallbackShouldPlay: playbackWasRequested || shouldResumeAfterBuffering,
            fallbackRate: player.rate > 0 ? player.rate : player.defaultRate
        )
        pendingSourceSwitchTime = recovery.position
        pendingSourceSwitchShouldPlay = recovery.shouldPlay
        pendingSourceSwitchRate = recovery.rate
        nextReplacementShouldPlay = recovery.shouldPlay
        automaticSourceRefreshAttempts += 1
        recoveryAttemptCount = automaticSourceRefreshAttempts
        recoveryBaselinePosition = position
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        isBuffering = nextReplacementShouldPlay == true
        sourceRefreshTask = Task { @MainActor [weak self] in
            let succeeded = await onSourceRefreshNeeded()
            guard let self, !Task.isCancelled else { return }
            self.sourceRefreshTask = nil
            if !succeeded {
                self.sourceRefreshRequestedForURL = nil
                self.failPlaybackRecovery()
            }
        }
    }

    private func handleItemFailure() {
        // A signed HLS item can fail while paused. AVPlayer does not publish the
        // same status transition again when its system Play button is pressed,
        // leaving the crossed-out play icon stuck unless we replace the item.
        if let lastItemFailureAt, Date().timeIntervalSince(lastItemFailureAt) < 0.9 {
            return
        }
        lastItemFailureAt = Date()
        let shouldContinuePlaying = playbackWasRequested || shouldResumeAfterBuffering
        isPreparingPlayback = false
        shouldResumeAfterBuffering = shouldContinuePlaying
        isBuffering = shouldContinuePlaying
        playbackErrorMessage = nil
        requestSourceRefresh()
    }

    private var isSeekRecoveryGraceActive: Bool {
        guard let seekRecoveryGraceUntil else { return false }
        return Date() < seekRecoveryGraceUntil
    }

    private func beginSeekRecoveryGrace() {
        playbackState = .seeking
        seekRecoveryGraceUntil = Date().addingTimeInterval(PlaybackRecoveryPolicy.seekGracePeriod)
        stagnantBufferChecks = 0
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
    }

    private func finishSeek() {
        refreshPlaybackState()
        if playbackWasRequested,
           player.timeControlStatus != .playing {
            scheduleRecoveryWatchdogIfNeeded()
        }
    }

    private func scheduleRecoveryWatchdogIfNeeded() {
        guard recoveryWatchdogTask == nil,
              playbackWasRequested,
              player.currentItem != nil else { return }
        lastObservedBufferEnd = bufferedEndTime()
        stagnantBufferChecks = 0
        // AVPlayer has no terminal event for a server that stays connected but
        // stops delivering media. This deliberately long watchdog is only a
        // last-resort detector for that case; ordinary buffering remains under
        // AVPlayer's automatic wait-and-resume control.
        recoveryWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: PlaybackRecoveryPolicy.watchdogInterval)
                } catch {
                    return
                }
                guard let self,
                      self.playbackWasRequested,
                      (self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                        || self.shouldResumeAfterBuffering) else { return }

                let bufferedEnd = self.bufferedEndTime()
                if bufferedEnd >= self.lastObservedBufferEnd + PlaybackRecoveryPolicy.minimumBufferGrowth {
                    self.lastObservedBufferEnd = bufferedEnd
                    self.stagnantBufferChecks = 0
                    continue
                }

                self.stagnantBufferChecks += 1
                switch PlaybackRecoveryPolicy.action(
                    trigger: .stagnantBuffer(
                        checks: self.stagnantBufferChecks,
                        seekGraceActive: self.isSeekRecoveryGraceActive
                    ),
                    sourceRefreshAttempts: self.automaticSourceRefreshAttempts
                ) {
                case .refreshSource:
                    self.recoveryWatchdogTask = nil
                    self.requestSourceRefresh()
                    return
                case .fail:
                    self.recoveryWatchdogTask = nil
                    self.failPlaybackRecovery()
                    return
                case .keepWaiting:
                    break
                }
            }
        }
    }

    private func bufferedEndTime() -> Double {
        guard let item = player.currentItem else { return 0 }
        return item.loadedTimeRanges.reduce(0) { result, value in
            let range = value.timeRangeValue
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            return end.isFinite ? max(result, end) : result
        }
    }

    private func failPlaybackRecovery() {
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        shouldResumeAfterBuffering = false
        isPreparingPlayback = false
        playbackWasRequested = false
        isBuffering = false
        playbackState = .failed
        player.pause()
        playbackErrorMessage =
            "Couldn't keep this stream playing. Tap Retry to reconnect, or Try next source for another mirror."
        publishNowPlayingInfo()
    }

    static func expirationDate(in url: URL) -> Date? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let value = query.first(where: { $0.name == "expires" })?.value, let timestamp = TimeInterval(value) {
            return Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1_000 : timestamp)
        }
        if let token = query.first(where: { $0.name == "token" })?.value?.split(separator: ".").first {
            var payload = String(token).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
            if let data = Data(base64Encoded: payload), let text = String(data: data, encoding: .utf8),
               let first = text.split(separator: "|").first, let seconds = TimeInterval(first) {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    private func observeAudioSessionEvents() {
        let audioSession = AVAudioSession.sharedInstance()
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
                return
            }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(typeRawValue: rawType, optionsRawValue: rawOptions)
            }
        }
        audioRouteChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleAudioRouteChange(reasonRawValue: rawReason)
            }
        }
    }

    private func handleAudioInterruption(typeRawValue: UInt, optionsRawValue: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRawValue) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = playbackWasRequested
                && player.timeControlStatus != .paused
            recoveryWatchdogTask?.cancel()
            recoveryWatchdogTask = nil
            isBuffering = false
            Task { [audioSessionController] in
                await audioSessionController.markInactive()
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRawValue)
            guard wasPlayingBeforeInterruption, options.contains(.shouldResume) else {
                wasPlayingBeforeInterruption = false
                return
            }
            wasPlayingBeforeInterruption = false
            playbackWasRequested = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.audioSessionController.activateForPlayback()
                self.player.play()
            }
        @unknown default:
            break
        }
    }

    private func handleAudioRouteChange(reasonRawValue: UInt) {
        guard AVAudioSession.RouteChangeReason(rawValue: reasonRawValue) == .oldDeviceUnavailable else {
            return
        }
        player.pause()
        playbackWasRequested = false
        shouldResumeAfterBuffering = false
        isBuffering = false
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        publishNowPlayingInfo()
    }

    private func applyPreferredLanguages(
        to asset: AVAsset,
        primarySubtitleLanguage: String,
        secondarySubtitleLanguage: String,
        audioLanguage: String,
        preferredSubtitleDisplayName: String? = nil,
        preferredSubtitleSelectionID: String? = nil
    ) async {
        isApplyingPreferredLanguages = true
        defer { isApplyingPreferredLanguages = false }
        let subtitleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled else { return }
        let audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        guard !Task.isCancelled, player.currentItem?.asset === asset else { return }

        var embeddedSubtitle: AVMediaSelectionOption?
        if let subtitleGroup {
            for option in subtitleGroup.options {
                let identity = await subtitleSelectionID(option)
                if identity == preferredSubtitleSelectionID || identity == preferredSubtitleDisplayName {
                    embeddedSubtitle = option
                    break
                }
            }
            var nativeOptions: [AVMediaSelectionOption] = []
            var injectedOptions: [AVMediaSelectionOption] = []
            for option in subtitleGroup.options {
                if await isInjectedSubtitleOption(option) {
                    injectedOptions.append(option)
                } else {
                    nativeOptions.append(option)
                }
            }
            if embeddedSubtitle == nil {
                embeddedSubtitle = await preferredOption(
                    in: nativeOptions, languageCodes: [primarySubtitleLanguage]
                )
            }
            if embeddedSubtitle == nil {
                embeddedSubtitle = await preferredOption(
                    in: injectedOptions, languageCodes: [primarySubtitleLanguage]
                )
            }
            if embeddedSubtitle == nil {
                embeddedSubtitle = await preferredOption(
                    in: nativeOptions, languageCodes: [secondarySubtitleLanguage]
                )
            }
            if embeddedSubtitle == nil {
                embeddedSubtitle = await preferredOption(
                    in: injectedOptions, languageCodes: [secondarySubtitleLanguage]
                )
            }
        }
        if preferredSubtitleSelectionID == "__subtitles_off__" { embeddedSubtitle = nil }
        if let subtitleGroup {
            player.currentItem?.select(embeddedSubtitle, in: subtitleGroup)
            if let embeddedSubtitle {
                subtitleVisibilityObservation.noteSelectedTrack()
                subtitleVisibilityBaseline = true
                canAdjustSubtitleTiming = await isInjectedSubtitleOption(embeddedSubtitle)
            } else {
                // No matching track yet is not the viewer choosing Off. Keep
                // the requested-on intent while background enrichment runs.
                if !subtitleUserRequestedOn || preferredSubtitleSelectionID == "__subtitles_off__" {
                    subtitleVisibilityBaseline = false
                }
                canAdjustSubtitleTiming = false
            }
        } else {
            canAdjustSubtitleTiming = false
        }
        if let item = player.currentItem, item.asset === asset {
            refreshSubtitleTimingAvailability(for: item)
        }
        if let audioGroup {
            let audio = await preferredOption(in: audioGroup.options, languageCodes: [audioLanguage, "en"])
            if let audio { player.currentItem?.select(audio, in: audioGroup) }
        }
        applySubtitleAppearance()
        await refreshSubtitlePickerEntries()
    }

    private func recordSubtitleVisibilityChange(for item: AVPlayerItem) {
        guard !isApplyingPreferredLanguages, !isStabilizingMediaSelection else { return }
        Task { [weak self, weak item] in
            guard let self, let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  self.player.currentItem === item else { return }
            let isEnabled = item.currentMediaSelection.selectedMediaOption(in: group) != nil
            guard self.subtitleVisibilityObservation.shouldPersistSelection(
                isSelected: isEnabled,
                subtitlesRequestedOn: self.subtitleUserRequestedOn
            ) else {
                SubtitleDiagnostics.logger.info(
                    "SUBTITLE PERF media selection empty while preferred track is pending; keeping subtitles enabled"
                )
                return
            }
            guard self.subtitleVisibilityBaseline != isEnabled else { return }
            let previousVisibility = self.subtitleVisibilityBaseline.map {
                $0 ? "on" : "off"
            } ?? "unset"
            SubtitleDiagnostics.logger.info(
                "SUBTITLE PERF media selection visibility CHANGED content=\(self.currentContentID ?? "unknown", privacy: .public) previous=\(previousVisibility, privacy: .public) enabled=\(isEnabled)"
            )
            self.subtitleVisibilityBaseline = isEnabled
            self.subtitleUserRequestedOn = isEnabled
            self.onSubtitleVisibilityChanged?(isEnabled)
        }
    }

    private func reapplyPreferredLanguagesIfNeeded(
        to item: AVPlayerItem,
        preferredSubtitleDisplayName: String?,
        preferredSubtitleSelectionID: String?
    ) {
        // The initial task owns the readiness/selection/playback sequence. If
        // readiness arrives while it is active, that task will apply the final
        // selection itself and must not be cancelled by this observation.
        guard mediaOptionsTask == nil,
              subtitleSelectionAuthority.allowsAutomaticSelection else { return }
        mediaOptionsTask?.cancel()
        mediaOptionsTask = Task { [weak self, weak item] in
            guard let self, let item, self.player.currentItem === item else { return }
            await self.applyPreferredLanguages(
                to: item.asset,
                primarySubtitleLanguage: self.primarySubtitleLanguage,
                secondarySubtitleLanguage: self.secondarySubtitleLanguage,
                audioLanguage: self.audioLanguage,
                preferredSubtitleDisplayName: preferredSubtitleDisplayName,
                preferredSubtitleSelectionID: preferredSubtitleSelectionID
            )
        }
    }

    private func selectedSubtitleDisplayName() async -> String? {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return nil }
        guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return await subtitleSelectionID(option)
    }

    private func logSubtitleDiagnostics(at playerTime: Double) async {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else {
            SubtitleDiagnostics.logger.notice("SUBSYNC player: no legible media-selection group")
            return
        }
        let selected = item.currentMediaSelection.selectedMediaOption(in: group)
        SubtitleDiagnostics.logger.notice(
            "SUBSYNC player: time=\(playerTime, privacy: .public) optionCount=\(group.options.count, privacy: .public)"
        )
        for (index, option) in group.options.enumerated() {
            let isSelected = selected.map { option == $0 } ?? false
            let identity = await subtitleSelectionID(option)
            let title = await subtitleTitle(option) ?? "none"
            let languageTag = option.extendedLanguageTag ?? "none"
            let rendition = subtitleRenditionsBySelectionID[identity]
                ?? subtitleRenditionsByDisplayName[identity]
            let sourceTime = playerTime - (rendition?.timingOffset ?? 0)
            let cue = rendition?.cues.first {
                $0.startTime <= sourceTime && sourceTime < $0.endTime
            }
            SubtitleDiagnostics.logger.notice(
                "SUBSYNC option[\(index, privacy: .public)]: selected=\(isSelected, privacy: .public) identity=\(identity, privacy: .public) tag=\(languageTag, privacy: .public) display=\(option.displayName, privacy: .public) title=\(title, privacy: .public) provider=\(rendition?.subtitle.providerID ?? "unmapped", privacy: .public) label=\(rendition?.subtitle.label ?? "unmapped", privacy: .public) offset=\(rendition?.timingOffset ?? -999, privacy: .public) cueStart=\(cue?.startTime ?? -1, privacy: .public) cueEnd=\(cue?.endTime ?? -1, privacy: .public)"
            )
        }
    }

    private func subtitleTitle(_ option: AVMediaSelectionOption) async -> String? {
        for item in option.commonMetadata where item.commonKey == .commonKeyTitle {
            if let title = try? await item.load(.stringValue), !title.isEmpty { return title }
        }
        return nil
    }

    private func selectedSubtitleSelectionID() async -> String? {
        guard let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item else { return nil }
        guard let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return await subtitleSelectionID(option)
    }

    private func recordSelectedSubtitlePreference(from item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
              player.currentItem === item,
              let option = item.currentMediaSelection.selectedMediaOption(in: group) else { return }
        let selectionID = await subtitleSelectionID(option)
        let displayName = option.displayName
        if let rendition = subtitleRenditionsBySelectionID[selectionID]
            ?? subtitleRenditionsByDisplayName[displayName] {
            onSubtitleSelectionChanged?(
                SubtitleSelectionPreference(
                    baseSubtitleKey: rendition.subtitle.syncKey,
                    syncVersionID: rendition.syncVersionID
                )
            )
            return
        }
        let optionLanguage = SubtitleLanguage.canonicalCode(
            option.extendedLanguageTag ?? option.locale?.identifier
        )
        if let descriptor = nativeSubtitleDescriptors.first(where: { descriptor in
            let nameMatches =
                descriptor.name.localizedCaseInsensitiveCompare(displayName) == .orderedSame
                || descriptor.subtitleSource.label.localizedCaseInsensitiveCompare(displayName) == .orderedSame
            let languageMatches = optionLanguage == nil
                || descriptor.subtitleSource.canonicalLanguageCode == optionLanguage
            return nameMatches && languageMatches
        }) {
            onSubtitleSelectionChanged?(
                SubtitleSelectionPreference(
                    baseSubtitleKey: descriptor.subtitleSource.syncKey,
                    syncVersionID: nil
                )
            )
        }
    }

    private func refreshSubtitleTimingAvailability(for item: AVPlayerItem) {
        Task { [weak self, weak item] in
            guard let self, let item,
                  let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  self.player.currentItem === item else { return }
            let selected = item.currentMediaSelection.selectedMediaOption(in: group)
            if let selected {
                self.canAdjustSubtitleTiming = await self.isInjectedSubtitleOption(selected)
                let selectionID = await self.subtitleSelectionID(selected)
                let rendition = self.subtitleRenditionsBySelectionID[selectionID]
                    ?? self.subtitleRenditionsByDisplayName[selectionID]
                SubtitleDiagnostics.logger.notice(
                    "SUBSYNC selected: selectionID=\(selectionID, privacy: .public) provider=\(rendition?.subtitle.providerID ?? "native", privacy: .public)"
                )
            } else {
                self.canAdjustSubtitleTiming = false
                SubtitleDiagnostics.logger.notice(
                    "SUBSYNC selected: selectionID=off provider=none"
                )
            }
        }
    }

    private func subtitleSelectionID(_ option: AVMediaSelectionOption) async -> String {
        if let title = await subtitleTitle(option) { return title }
        return option.displayName
    }

    private func isInjectedSubtitleOption(_ option: AVMediaSelectionOption) async -> Bool {
        return injectedSubtitleNames.contains(await subtitleSelectionID(option))
    }

    private func preferredOption(
        in options: [AVMediaSelectionOption],
        languageCodes: [String]
    ) async -> AVMediaSelectionOption? {
        var matchingForcedOption: AVMediaSelectionOption?
        for code in languageCodes where !code.isEmpty {
            guard let preferredLanguage = SubtitleLanguage.canonicalCode(code) else { continue }
            var matches: [AVMediaSelectionOption] = []
            for option in options {
                let selectionID = await subtitleSelectionID(option)
                let renditionLanguage = (subtitleRenditionsBySelectionID[selectionID]
                    ?? subtitleRenditionsByDisplayName[selectionID])?.subtitle.canonicalLanguageCode
                let tags = [option.extendedLanguageTag, option.locale?.identifier]
                    .compactMap { SubtitleLanguage.canonicalCode($0) }
                if renditionLanguage == preferredLanguage || tags.contains(preferredLanguage) {
                    matches.append(option)
                }
            }
            if let regular = matches.first(where: {
                !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            }) {
                return regular
            }
            matchingForcedOption = matchingForcedOption ?? matches.first
        }
        return matchingForcedOption
    }

    private func configureNowPlaying(for request: PlaybackRequest) {
        configureRemoteCommandsIfNeeded()
        nowPlayingArtworkTask?.cancel()
        nowPlayingContentID = request.contentID
        nowPlayingTitle = request.nowPlayingTitle
        nowPlayingSubtitle = request.nowPlayingSubtitle
        nowPlayingArtwork = nil
        publishNowPlayingInfo()

        guard let posterURL = request.media.posterURL else { return }
        var posterRequest = URLRequest.providerRequest(url: posterURL)
        posterRequest.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let contentID = request.contentID
        let client = subtitleClient
        nowPlayingArtworkTask = Task { [weak self] in
            do {
                let response = try await client.data(for: posterRequest)
                try Task.checkCancellation()
                guard let image = UIImage(data: response.data),
                      let self,
                      self.nowPlayingContentID == contentID else { return }
                self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.publishNowPlayingInfo()
            } catch { }
        }
    }

    private func publishNowPlayingInfo() {
        guard let nowPlayingTitle, let nowPlayingContentID else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: nowPlayingTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate:
                playbackWasRequested
                    ? Double(
                        player.rate > 0
                            ? player.rate
                            : player.defaultRate
                    )
                    : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(player.defaultRate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier: nowPlayingContentID,
            MPNowPlayingInfoPropertyIsLiveStream: false
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let nowPlayingSubtitle {
            info[MPMediaItemPropertyArtist] = nowPlayingSubtitle
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = player.timeControlStatus == .paused ? .paused : .playing
    }

    private func clearNowPlaying() {
        nowPlayingContentID = nil
        nowPlayingTitle = nil
        nowPlayingSubtitle = nil
        nowPlayingArtwork = nil
        let center = MPNowPlayingInfoCenter.default()
        center.playbackState = .stopped
        center.nowPlayingInfo = nil
    }

    private func configureRemoteCommandsIfNeeded() {
        guard remoteCommandTargets.isEmpty else {
            return
        }

        UIApplication.shared
            .beginReceivingRemoteControlEvents()

        let center =
            MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        let playTarget = center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeFromRemoteCommand() }
            return .success
        }
        remoteCommandTargets.append((center.playCommand, playTarget))

        center.pauseCommand.isEnabled = true
        let pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.pauseFromRemoteCommand() }
            return .success
        }
        remoteCommandTargets.append((center.pauseCommand, pauseTarget))

        center.togglePlayPauseCommand.isEnabled = true
        let toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in self?.togglePlaybackFromRemoteCommand() }
            return .success
        }
        remoteCommandTargets.append((center.togglePlayPauseCommand, toggleTarget))

        center.changePlaybackPositionCommand.isEnabled = true
        let positionTarget = center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = positionEvent.positionTime
            Task { @MainActor [weak self] in self?.seekFromRemoteCommand(to: position) }
            return .success
        }
        remoteCommandTargets.append((center.changePlaybackPositionCommand, positionTarget))

        center.previousTrackCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [15]

        let skipBackwardTarget =
            center.skipBackwardCommand.addTarget {
                [weak self] _ in

                Task { @MainActor [weak self] in
                    guard let self else { return }

                    self.seekFromRemoteCommand(
                        to: max(
                            0,
                            self.position - 15
                        )
                    )
                }

                return .success
            }

        remoteCommandTargets.append(
            (
                center.skipBackwardCommand,
                skipBackwardTarget
            )
        )

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [15]

        let skipForwardTarget =
            center.skipForwardCommand.addTarget {
                [weak self] _ in

                Task { @MainActor [weak self] in
                    guard let self else { return }

                    let target =
                        self.duration > 0
                        ? min(
                            self.duration,
                            self.position + 15
                        )
                        : self.position + 15

                    self.seekFromRemoteCommand(
                        to: target
                    )
                }

                return .success
            }

        remoteCommandTargets.append(
            (
                center.skipForwardCommand,
                skipForwardTarget
            )
        )
    }

    private func removeRemoteCommands() {
        for target in remoteCommandTargets {
            target.command.removeTarget(target.target)
        }
        remoteCommandTargets.removeAll()

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        UIApplication.shared
            .endReceivingRemoteControlEvents()
    }

    private func resumeFromRemoteCommand() {
        guard let item = player.currentItem else { return }
        playbackWasRequested = true
        playbackErrorMessage = nil
        let currentTime = item.currentTime().seconds
        let itemDuration = item.duration.seconds
        let rate = Float(playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1)

        if currentTime.isFinite,
           itemDuration.isFinite,
           itemDuration > 0,
           currentTime >= itemDuration - 0.5 {
            item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.player.playImmediately(atRate: rate)
                    self?.publishNowPlayingInfo()
                }
            }
        } else {
            player.playImmediately(atRate: rate)
            publishNowPlayingInfo()
        }
    }

    private func pauseFromRemoteCommand() {
        guard player.currentItem != nil else { return }
        playbackWasRequested = false
        shouldResumeAfterBuffering = false
        isBuffering = false
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        player.pause()
        publishNowPlayingInfo()
    }

    private func togglePlaybackFromRemoteCommand() {
        if player.timeControlStatus == .paused {
            resumeFromRemoteCommand()
        } else {
            pauseFromRemoteCommand()
        }
    }

    private func seekFromRemoteCommand(to position: TimeInterval) {
        guard player.currentItem != nil, position.isFinite else { return }
        seekForPlayback(to: position)
    }

    /// Performs an ordinary playback seek. AVPlayer remains responsible for
    /// fetching HLS segments; this only serializes user intent so stale seek
    /// completions cannot restore an older position or play/pause state.
    func seekForPlayback(to position: TimeInterval) {
        guard let item = player.currentItem, position.isFinite else { return }
        let shouldPlay = player.rate > 0 || player.timeControlStatus != .paused
        let rate = player.rate > 0 ? player.rate : player.defaultRate
        let request = playbackSeekState.begin(
            target: max(0, position),
            shouldPlay: shouldPlay,
            rate: rate
        )
        if sourceRefreshTask != nil || nextReplacementShouldPlay != nil {
            pendingSourceSwitchTime = request.target
            pendingSourceSwitchShouldPlay = request.shouldPlay
            pendingSourceSwitchRate = request.rate
            nextReplacementShouldPlay = request.shouldPlay
        }
        playbackWasRequested = shouldPlay
        shouldResumeAfterBuffering = shouldPlay
        beginSeekRecoveryGrace()
        item.cancelPendingSeeks()
        player.seek(
            to: CMTime(seconds: request.target, preferredTimescale: 600),
            toleranceBefore: PlaybackSeekPolicy.normalTolerance,
            toleranceAfter: PlaybackSeekPolicy.normalTolerance
        ) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self,
                      let completed = self.playbackSeekState.complete(request.id, finished: finished) else { return }
                if completed.shouldPlay {
                    self.player.playImmediately(atRate: completed.rate)
                } else {
                    self.player.pause()
                }
                self.finishSeek()
                self.publishNowPlayingInfo()
            }
        }
    }

    private func applyQuality(to item: AVPlayerItem) {
        guard let selectedQuality else {
            item.preferredPeakBitRate = automaticPeakBitRate ?? 0
            item.preferredMaximumResolution = .zero
            return
        }
        item.preferredPeakBitRate = selectedQuality.peakBitRate * 1.02
        item.preferredMaximumResolution = CGSize(
            width: selectedQuality.width,
            height: selectedQuality.height
        )
    }

    private func removeInjectedSubtitleAsset() {
        subtitleServer.clear()
        injectedSubtitleNames = []
        injectedSubtitleLanguageTags = []
        subtitleRenditions = []
        subtitleRenditionsByDisplayName = [:]
        subtitleRenditionsBySelectionID = [:]
        subtitleStudioTracks = []
        subtitlePlaybackSource = nil
        canAdjustSubtitleTiming = false
        canOpenSubtitleStudio = false
    }
}

enum PlaybackSessionState: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case seeking
    case buffering
    case recovering
    case failed
}

enum PlaybackSeekPolicy {
    // Normal HLS playback benefits from keyframe/segment-aligned seeks. Subtitle
    // Studio continues to use zero tolerance in its separate seek path.
    static let normalTolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
}

struct PlaybackSeekRequest: Equatable, Sendable {
    let id: UInt64
    let target: TimeInterval
    let shouldPlay: Bool
    let rate: Float
}

struct PlaybackSeekRecoverySnapshot: Equatable, Sendable {
    let position: TimeInterval
    let shouldPlay: Bool
    let rate: Float
}

struct PlaybackSeekState: Sendable {
    private(set) var latestRequest: PlaybackSeekRequest?
    private var nextID: UInt64 = 0

    mutating func begin(target: TimeInterval, shouldPlay: Bool, rate: Float) -> PlaybackSeekRequest {
        nextID &+= 1
        let request = PlaybackSeekRequest(
            id: nextID,
            target: target,
            shouldPlay: shouldPlay,
            rate: rate.isFinite && rate > 0 ? rate : 1
        )
        latestRequest = request
        return request
    }

    mutating func complete(_ id: UInt64, finished: Bool) -> PlaybackSeekRequest? {
        guard finished, latestRequest?.id == id else { return nil }
        let completed = latestRequest
        latestRequest = nil
        return completed
    }

    func recoverySnapshot(
        currentPosition: TimeInterval,
        fallbackShouldPlay: Bool,
        fallbackRate: Float
    ) -> PlaybackSeekRecoverySnapshot {
        if let latestRequest {
            return .init(
                position: latestRequest.target,
                shouldPlay: latestRequest.shouldPlay,
                rate: latestRequest.rate
            )
        }
        return .init(
            position: max(0, currentPosition),
            shouldPlay: fallbackShouldPlay,
            rate: fallbackRate.isFinite && fallbackRate > 0 ? fallbackRate : 1
        )
    }

    mutating func reset() {
        latestRequest = nil
    }
}

enum PlaybackRecoveryTrigger: Equatable, Sendable {
    case stagnantBuffer(checks: Int, seekGraceActive: Bool)
    case fatalPlaybackError
}

enum PlaybackRecoveryAction: Equatable, Sendable {
    case keepWaiting
    case refreshSource
    case fail
}

enum PlaybackRecoveryPolicy {
    /// Check buffer health more often so stalled streams recover sooner.
    static let watchdogInterval: Duration = .seconds(4)
    static let minimumBufferGrowth = 0.25
    static let seekGracePeriod: TimeInterval = 8
    static let stagnantChecksBeforeRecovery = 2
    static let maximumSourceRefreshes = 5

    static func action(
        trigger: PlaybackRecoveryTrigger,
        sourceRefreshAttempts: Int
    ) -> PlaybackRecoveryAction {
        switch trigger {
        case .fatalPlaybackError:
            return sourceRefreshAttempts >= maximumSourceRefreshes ? .fail : .refreshSource
        case let .stagnantBuffer(checks, seekGraceActive):
            guard !seekGraceActive,
                  checks >= stagnantChecksBeforeRecovery else { return .keepWaiting }
            return sourceRefreshAttempts >= maximumSourceRefreshes ? .fail : .refreshSource
        }
    }
}

struct StreamQuality: Identifiable, Hashable, Sendable {
    let width: Int
    let height: Int
    let peakBitRate: Double

    var id: Int { height }
    var title: String { "\(height)p" }

    static func closest(to preferredHeight: Int, in qualities: [StreamQuality]) -> StreamQuality? {
        guard preferredHeight > 0 else { return nil }
        return qualities.last(where: { $0.height <= preferredHeight }) ?? qualities.first
    }
}

actor HLSPlaylistInspector {
    private let client: any HTTPClientProtocol

    init(client: any HTTPClientProtocol = HTTPClient()) {
        self.client = client
    }

    func availableQualities(for source: PlaybackSource) async -> [StreamQuality] {
        guard source.url.pathExtension.lowercased() != "mp4" else { return [] }
        do {
            var request = URLRequest(url: source.url)
            for (name, value) in source.headers { request.setValue(value, forHTTPHeaderField: name) }
            let response = try await client.data(for: request)
            try Task.checkCancellation()
            guard let playlist = String(data: response.data, encoding: .utf8) else { return [] }
            return HLSMasterPlaylistParser.qualities(from: playlist)
        } catch {
            return []
        }
    }
}

enum HLSMasterPlaylistParser {
    static func qualities(from playlist: String) -> [StreamQuality] {
        var byHeight: [Int: StreamQuality] = [:]
        for line in playlist.split(whereSeparator: \.isNewline) {
            let value = String(line)
            guard value.hasPrefix("#EXT-X-STREAM-INF:"),
                  let resolution = capture(#"RESOLUTION=(\d+)x(\d+)"#, in: value),
                  let width = Int(resolution[0]),
                  let height = Int(resolution[1]) else { continue }
            let averageBandwidth = capture(#"AVERAGE-BANDWIDTH=(\d+)"#, in: value)?.first.flatMap(Double.init)
            let bandwidth = capture(#"(?:^|,)BANDWIDTH=(\d+)"#, in: value)?.first.flatMap(Double.init)
            let quality = StreamQuality(
                width: width,
                height: height,
                peakBitRate: averageBandwidth ?? bandwidth ?? 0
            )
            if quality.peakBitRate >= (byHeight[height]?.peakBitRate ?? -1) {
                byHeight[height] = quality
            }
        }
        return byHeight.values.sorted { $0.height < $1.height }
    }

    /// Returns a valid master playlist that exposes only variants at the
    /// requested resolution. Keeping the master (instead of opening a media
    /// playlist directly) preserves alternate audio and subtitle groups.
    static func playlist(_ playlist: String, filteredToHeight targetHeight: Int) -> String {
        let lines = playlist.components(separatedBy: .newlines)
        guard lines.contains(where: {
            $0.hasPrefix("#EXT-X-STREAM-INF:") && resolutionHeight(in: $0) == targetHeight
        }) else { return playlist }

        var output: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let keepVariant = resolutionHeight(in: line) == targetHeight
                if keepVariant { output.append(line) }
                index += 1
                while index < lines.count {
                    let followingLine = lines[index]
                    let isVariantURI = !followingLine.isEmpty && !followingLine.hasPrefix("#")
                    if keepVariant { output.append(followingLine) }
                    index += 1
                    if isVariantURI { break }
                }
                continue
            }
            if line.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:"),
               let height = resolutionHeight(in: line),
               height != targetHeight {
                index += 1
                continue
            }
            output.append(line)
            index += 1
        }
        return output.joined(separator: "\n")
    }

    private static func resolutionHeight(in line: String) -> Int? {
        capture(#"RESOLUTION=\d+x(\d+)"#, in: line)?.first.flatMap(Int.init)
    }

    private static func capture(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: value).map { String(value[$0]) }
        }
    }
}

private extension PlaybackSource {
    func preferredForSubtitleLanguage(_ languageCode: String) -> PlaybackSource {
        guard !languageCode.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return self }
        var queryItems = components.queryItems ?? []
        if let index = queryItems.firstIndex(where: { $0.name == "language" }) {
            queryItems[index] = URLQueryItem(name: "language", value: languageCode)
        } else {
            queryItems.append(URLQueryItem(name: "language", value: languageCode))
        }
        components.queryItems = queryItems
        guard let preferredURL = components.url else { return self }
        var preferredHeaders = headers
        preferredHeaders["Accept-Language"] = "\(languageCode),en;q=0.8"
        preferredHeaders["Cookie"] = "language=\(languageCode)"
        return PlaybackSource(
            url: preferredURL,
            headers: preferredHeaders,
            subtitles: subtitles,
            preferredPeakBitRate: preferredPeakBitRate
        )
    }
}

private actor AudioSessionController {
    private var isActive = false

    func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.allowAirPlay])
            try session.setActive(true)
            isActive = true
        } catch {
            isActive = false
        }
    }

    func markInactive() {
        isActive = false
    }

    func deactivate() {
        guard isActive else { return }
        defer { isActive = false }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}

final class LayoutAwarePlayerViewController: AVPlayerViewController {
    var onLayout: ((LayoutAwarePlayerViewController) -> Void)?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?(self)
    }
}

struct NativePlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let isZoomedToFill: Bool
    let isBuffering: Bool
    let playbackErrorMessage: String?
    let availableQualities: [StreamQuality]
    let selectedQuality: StreamQuality?
    let streams: [PlayableStream]
    let selectedSourceID: String?
    let automaticSource: Bool
    let isSearchingForSources: Bool
    let onSourceChanged: (String?, StreamQuality?) -> Void
    let subtitleTimingOffset: Double
    let canAdjustSubtitleTiming: Bool
    let onQualityChanged: (StreamQuality?) -> Void
    let onAdjustSubtitleTiming: (Double) -> Void
    let onOpenSubtitleSync: () -> Void
    let onOpenSubtitlePicker: () -> Void
    let onRetryPlayback: () -> Void
    let onTryNextSource: () -> Void
    let onZoomChanged: (Bool) -> Void
    let onWillDismiss: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            availableQualities: availableQualities,
            selectedQuality: selectedQuality,
            onQualityChanged: onQualityChanged,
            onAdjustSubtitleTiming: onAdjustSubtitleTiming,
            onOpenSubtitleSync: onOpenSubtitleSync,
            onOpenSubtitlePicker: onOpenSubtitlePicker,
            onRetryPlayback: onRetryPlayback,
            onTryNextSource: onTryNextSource,
            isZoomedToFill: isZoomedToFill,
            onZoomChanged: onZoomChanged,
            onWillDismiss: onWillDismiss,
            onDismiss: onDismiss
        )
    }

    func makeUIViewController(context: Context) -> LayoutAwarePlayerViewController {
        let controller = LayoutAwarePlayerViewController()
        controller.updatesNowPlayingInfoCenter = false
        controller.player = player
        controller.delegate = context.coordinator
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        // PlayerScreen is already presented as a full-screen cover. Letting
        // AVKit present another full-screen layer causes a second close step
        // after replacing an item during a source switch.
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.onLayout = { [weak coordinator = context.coordinator] controller in
            coordinator?.playerViewDidLayout(controller)
        }
        context.coordinator.installControls(in: controller)
        return controller
    }

    func updateUIViewController(_ controller: LayoutAwarePlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
        context.coordinator.updateZoomPreference(isZoomedToFill, in: controller)
        context.coordinator.updateQualities(
            availableQualities,
            selectedQuality: selectedQuality
        )
        context.coordinator.updateSources(streams, selectedID: selectedSourceID,
            automatic: automaticSource, isSearching: isSearchingForSources, onChanged: onSourceChanged)
        context.coordinator.updateSubtitleTiming(
            offset: subtitleTimingOffset,
            isAvailable: canAdjustSubtitleTiming
        )
        context.coordinator.updateBuffering(isBuffering)
        context.coordinator.updatePlaybackError(playbackErrorMessage)
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        private let systemVolumeHUDSuppressor = MPVolumeView(frame: .zero)
        private let settingsButton = UIButton(type: .system)
        private let bufferingIndicator = UIActivityIndicatorView(style: .large)
        private let playbackErrorView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        private let playbackErrorLabel = UILabel()
        private let retryPlaybackButton = UIButton(type: .system)
        private let tryNextSourceButton = UIButton(type: .system)
        private let subtitleTimingControl = UIStackView()
        private let subtitleTimingLabel = UILabel()
        private let decreaseSubtitleTimingButton = UIButton(type: .system)
        private let increaseSubtitleTimingButton = UIButton(type: .system)
        private var streams: [PlayableStream] = []
        private var selectedSourceID: String?
        private var automaticSource = true
        private var isSearchingForSources = false
        private var sourceMenuSignature = ""
        private var onSourceChanged: ((String?, StreamQuality?) -> Void)?
        private var availableQualities: [StreamQuality]
        private var selectedQuality: StreamQuality?
        private let onQualityChanged: (StreamQuality?) -> Void
        private let onAdjustSubtitleTiming: (Double) -> Void
        private let onOpenSubtitleSync: () -> Void
        private let onOpenSubtitlePicker: () -> Void
        private let onRetryPlayback: () -> Void
        private let onTryNextSource: () -> Void
        private let onWillDismiss: () -> Void
        private var subtitleTimingAvailable = false
        private var lastPlaybackErrorMessage: String?
        private var hideTask: Task<Void, Never>?
        private weak var player: AVPlayer?
        private weak var playerViewController: AVPlayerViewController?
        private var prefersZoomedToFill: Bool
        private var lastIsLandscape: Bool?
        private var gesturesInstalled = false
        private var volumeHUDInstalled = false
        private var tapGestureRecognizer: UITapGestureRecognizer?
        private var doubleTapGestureRecognizer: UITapGestureRecognizer?
        private var panGestureRecognizer: UIPanGestureRecognizer?
        private var pinchGestureRecognizer: UIPinchGestureRecognizer?
        private let onZoomChanged: (Bool) -> Void
        let onDismiss: () -> Void
        private var panStartLocation: CGPoint = .zero
        private var panMode: VerticalPanMode?
        private var initialVolume: Float = 0
        private var initialBrightness: CGFloat = UIScreen.main.brightness
        private let gestureFeedbackLabel: UILabel = {
            let label = UILabel()
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textAlignment = .center
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            label.textColor = .white
            label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            label.layer.cornerRadius = 12
            label.clipsToBounds = true
            label.alpha = 0
            label.isAccessibilityElement = false
            return label
        }()

        private enum VerticalPanMode {
            case volume
            case brightness
        }

        init(
            availableQualities: [StreamQuality],
            selectedQuality: StreamQuality?,
            onQualityChanged: @escaping (StreamQuality?) -> Void,
            onAdjustSubtitleTiming: @escaping (Double) -> Void,
            onOpenSubtitleSync: @escaping () -> Void,
            onOpenSubtitlePicker: @escaping () -> Void,
            onRetryPlayback: @escaping () -> Void,
            onTryNextSource: @escaping () -> Void,
            isZoomedToFill: Bool,
            onZoomChanged: @escaping (Bool) -> Void,
            onWillDismiss: @escaping () -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.availableQualities = availableQualities
            self.selectedQuality = selectedQuality
            self.onQualityChanged = onQualityChanged
            self.onAdjustSubtitleTiming = onAdjustSubtitleTiming
            self.onOpenSubtitleSync = onOpenSubtitleSync
            self.onOpenSubtitlePicker = onOpenSubtitlePicker
            self.onRetryPlayback = onRetryPlayback
            self.onTryNextSource = onTryNextSource
            prefersZoomedToFill = isZoomedToFill
            self.onZoomChanged = onZoomChanged
            self.onWillDismiss = onWillDismiss
            self.onDismiss = onDismiss
            super.init()
        }

        func installControls(in controller: AVPlayerViewController) {
            player = controller.player
            playerViewController = controller
            installSystemVolumeHUDSuppressor(in: controller.view)
            bufferingIndicator.translatesAutoresizingMaskIntoConstraints = false
            bufferingIndicator.color = .white
            bufferingIndicator.hidesWhenStopped = true
            bufferingIndicator.accessibilityLabel = "Buffering video"
            configurePlaybackErrorView()
            settingsButton.translatesAutoresizingMaskIntoConstraints = false
            settingsButton.showsMenuAsPrimaryAction = true
            settingsButton.accessibilityLabel = "Playback settings"
            configureSubtitleTimingControl()
            if let overlay = controller.contentOverlayView {
                attachControls(to: overlay)
            }
            installGesturesIfNeeded(on: controller.view)
            updateQualities(availableQualities, selectedQuality: selectedQuality)
            showSettingsButton()
        }

        private func installGesturesIfNeeded(on view: UIView) {
            guard !gesturesInstalled else { return }
            gesturesInstalled = true

            let tapGesture = UITapGestureRecognizer(target: self, action: #selector(playerTapped(_:)))
            tapGesture.cancelsTouchesInView = false
            tapGesture.delegate = self
            view.addGestureRecognizer(tapGesture)
            tapGestureRecognizer = tapGesture

            let doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(playerDoubleTapped(_:)))
            doubleTapGesture.numberOfTapsRequired = 2
            doubleTapGesture.cancelsTouchesInView = false
            doubleTapGesture.delegate = self
            view.addGestureRecognizer(doubleTapGesture)
            doubleTapGestureRecognizer = doubleTapGesture
            tapGesture.require(toFail: doubleTapGesture)

            let panGesture = UIPanGestureRecognizer(target: self, action: #selector(playerPanned(_:)))
            panGesture.cancelsTouchesInView = false
            panGesture.delegate = self
            view.addGestureRecognizer(panGesture)
            panGestureRecognizer = panGesture

            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(playerPinched(_:)))
            pinchGesture.cancelsTouchesInView = false
            pinchGesture.delegate = self
            view.addGestureRecognizer(pinchGesture)
            pinchGestureRecognizer = pinchGesture
        }

        private func attachControls(to overlay: UIView) {
            guard settingsButton.superview !== overlay else { return }
            bufferingIndicator.removeFromSuperview()
            playbackErrorView.removeFromSuperview()
            settingsButton.removeFromSuperview()
            subtitleTimingControl.removeFromSuperview()
            gestureFeedbackLabel.removeFromSuperview()
            overlay.addSubview(bufferingIndicator)
            overlay.addSubview(playbackErrorView)
            overlay.addSubview(settingsButton)
            overlay.addSubview(subtitleTimingControl)
            overlay.addSubview(gestureFeedbackLabel)
            NSLayoutConstraint.activate([
                bufferingIndicator.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                bufferingIndicator.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                playbackErrorView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                playbackErrorView.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
                playbackErrorView.widthAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.widthAnchor, constant: -40),
                settingsButton.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -14),
                settingsButton.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 10),
                settingsButton.widthAnchor.constraint(equalToConstant: 40),
                settingsButton.heightAnchor.constraint(equalToConstant: 40),
                subtitleTimingControl.trailingAnchor.constraint(equalTo: settingsButton.trailingAnchor),
                subtitleTimingControl.topAnchor.constraint(equalTo: settingsButton.bottomAnchor, constant: 10),
                subtitleTimingControl.widthAnchor.constraint(equalToConstant: 156),
                subtitleTimingControl.heightAnchor.constraint(equalToConstant: 44),
                gestureFeedbackLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                gestureFeedbackLabel.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 24),
                gestureFeedbackLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
                gestureFeedbackLabel.heightAnchor.constraint(equalToConstant: 36)
            ])
        }

        func updateZoomPreference(_ isZoomedToFill: Bool, in controller: AVPlayerViewController) {
            guard prefersZoomedToFill != isZoomedToFill else { return }
            prefersZoomedToFill = isZoomedToFill
            applyZoomPreference(in: controller)
        }

        func playerViewDidLayout(_ controller: AVPlayerViewController) {
            playerViewController = controller
            player = controller.player
            if let overlay = controller.contentOverlayView {
                attachControls(to: overlay)
            }
            installGesturesIfNeeded(on: controller.view)
            let isLandscape = controller.view.bounds.width > controller.view.bounds.height
            guard lastIsLandscape != isLandscape else { return }
            lastIsLandscape = isLandscape
            applyZoomPreference(in: controller)
        }

        private func applyZoomPreference(in controller: AVPlayerViewController) {
            let isLandscape = controller.view.bounds.width > controller.view.bounds.height
            controller.videoGravity = isLandscape && prefersZoomedToFill
                ? .resizeAspectFill
                : .resizeAspect
        }

        @objc private func playerPinched(_ gesture: UIPinchGestureRecognizer) {
            guard gesture.state == .ended || gesture.state == .cancelled else { return }
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let controller = self.playerViewController else { return }
                let isLandscape = controller.view.bounds.width > controller.view.bounds.height
                guard isLandscape else {
                    controller.videoGravity = .resizeAspect
                    return
                }
                let isZoomedToFill = controller.videoGravity == .resizeAspectFill
                guard self.prefersZoomedToFill != isZoomedToFill else { return }
                self.prefersZoomedToFill = isZoomedToFill
                self.onZoomChanged(isZoomedToFill)
            }
        }

        private func installSystemVolumeHUDSuppressor(in view: UIView) {
            guard !volumeHUDInstalled else { return }
            volumeHUDInstalled = true
            // AVPlayerViewController already presents its own volume slider. Keeping an
            // MPVolumeView attached makes iOS omit the second, system-level volume HUD.
            systemVolumeHUDSuppressor.translatesAutoresizingMaskIntoConstraints = false
            systemVolumeHUDSuppressor.isUserInteractionEnabled = false
            systemVolumeHUDSuppressor.accessibilityElementsHidden = true
            systemVolumeHUDSuppressor.alpha = 0.001
            view.addSubview(systemVolumeHUDSuppressor)
            NSLayoutConstraint.activate([
                systemVolumeHUDSuppressor.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                systemVolumeHUDSuppressor.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                systemVolumeHUDSuppressor.widthAnchor.constraint(equalToConstant: 1),
                systemVolumeHUDSuppressor.heightAnchor.constraint(equalToConstant: 1)
            ])
        }

        func updateBuffering(_ isBuffering: Bool) {
            if isBuffering && playbackErrorView.isHidden {
                bufferingIndicator.startAnimating()
            } else {
                bufferingIndicator.stopAnimating()
            }
        }

        func updatePlaybackError(_ message: String?) {
            guard lastPlaybackErrorMessage != message else { return }
            lastPlaybackErrorMessage = message
            playbackErrorLabel.text = message
            playbackErrorView.isHidden = message == nil
            if message == nil {
                return
            }
            bufferingIndicator.stopAnimating()
            UIAccessibility.post(notification: .announcement, argument: message)
        }

        private func configurePlaybackErrorView() {
            playbackErrorView.translatesAutoresizingMaskIntoConstraints = false
            playbackErrorView.layer.cornerRadius = 16
            playbackErrorView.clipsToBounds = true
            playbackErrorView.isHidden = true

            playbackErrorLabel.font = .preferredFont(forTextStyle: .body)
            playbackErrorLabel.textColor = .white
            playbackErrorLabel.textAlignment = .center
            playbackErrorLabel.numberOfLines = 0

            var retryConfiguration = UIButton.Configuration.filled()
            retryConfiguration.title = "Retry"
            retryConfiguration.image = UIImage(systemName: "arrow.clockwise")
            retryConfiguration.imagePadding = 8
            retryPlaybackButton.configuration = retryConfiguration
            retryPlaybackButton.accessibilityHint = "Reloads the stream and resumes from your current position"
            retryPlaybackButton.addTarget(self, action: #selector(retryPlayback), for: .touchUpInside)

            var nextConfiguration = UIButton.Configuration.bordered()
            nextConfiguration.title = "Try next source"
            nextConfiguration.image = UIImage(systemName: "rectangle.stack")
            nextConfiguration.imagePadding = 8
            nextConfiguration.baseForegroundColor = .white
            tryNextSourceButton.configuration = nextConfiguration
            tryNextSourceButton.accessibilityHint = "Switches to another available source for this title"
            tryNextSourceButton.addTarget(self, action: #selector(tryNextSource), for: .touchUpInside)

            let stack = UIStackView(arrangedSubviews: [playbackErrorLabel, retryPlaybackButton, tryNextSourceButton])
            stack.axis = .vertical
            stack.alignment = .center
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            playbackErrorView.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: playbackErrorView.contentView.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: playbackErrorView.contentView.trailingAnchor, constant: -20),
                stack.topAnchor.constraint(equalTo: playbackErrorView.contentView.topAnchor, constant: 18),
                stack.bottomAnchor.constraint(equalTo: playbackErrorView.contentView.bottomAnchor, constant: -18)
            ])
        }

        @objc private func retryPlayback() {
            playbackErrorView.isHidden = true
            bufferingIndicator.startAnimating()
            onRetryPlayback()
        }

        @objc private func tryNextSource() {
            playbackErrorView.isHidden = true
            bufferingIndicator.startAnimating()
            onTryNextSource()
        }

        func updateSubtitleTiming(offset: Double, isAvailable: Bool) {
            let becameAvailable = !subtitleTimingAvailable && isAvailable
            let availabilityChanged = subtitleTimingAvailable != isAvailable
            subtitleTimingAvailable = isAvailable
            subtitleTimingLabel.text = Self.subtitleTimingText(offset)
            subtitleTimingLabel.accessibilityValue = Self.subtitleTimingAccessibilityValue(offset)
            subtitleTimingControl.isHidden = !isAvailable
            if availabilityChanged { rebuildSettingsMenu() }
            if becameAvailable { showSettingsButton() }
        }

        private func configureSubtitleTimingControl() {
            subtitleTimingControl.axis = .horizontal
            subtitleTimingControl.alignment = .fill
            subtitleTimingControl.distribution = .fill
            subtitleTimingControl.spacing = 2
            subtitleTimingControl.translatesAutoresizingMaskIntoConstraints = false
            subtitleTimingControl.backgroundColor = UIColor(white: 0.14, alpha: 0.92)
            subtitleTimingControl.layer.cornerRadius = 12
            subtitleTimingControl.clipsToBounds = true
            subtitleTimingControl.isHidden = true

            configureTimingButton(
                decreaseSubtitleTimingButton,
                systemImage: "minus",
                accessibilityLabel: "Show subtitles earlier",
                action: #selector(decreaseSubtitleTiming)
            )
            configureTimingButton(
                increaseSubtitleTimingButton,
                systemImage: "plus",
                accessibilityLabel: "Show subtitles later",
                action: #selector(increaseSubtitleTiming)
            )
            subtitleTimingLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
            subtitleTimingLabel.textColor = .white
            subtitleTimingLabel.textAlignment = .center
            subtitleTimingLabel.accessibilityLabel = "Subtitle timing"
            subtitleTimingLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

            subtitleTimingControl.addArrangedSubview(decreaseSubtitleTimingButton)
            subtitleTimingControl.addArrangedSubview(subtitleTimingLabel)
            subtitleTimingControl.addArrangedSubview(increaseSubtitleTimingButton)
            NSLayoutConstraint.activate([
                decreaseSubtitleTimingButton.widthAnchor.constraint(equalToConstant: 42),
                increaseSubtitleTimingButton.widthAnchor.constraint(equalToConstant: 42)
            ])
        }

        private func configureTimingButton(
            _ button: UIButton,
            systemImage: String,
            accessibilityLabel: String,
            action: Selector
        ) {
            var configuration = UIButton.Configuration.plain()
            configuration.image = UIImage(systemName: systemImage)
            configuration.baseForegroundColor = .white
            button.configuration = configuration
            button.accessibilityLabel = accessibilityLabel
            button.addTarget(self, action: action, for: .touchUpInside)
        }

        @objc private func decreaseSubtitleTiming() {
            onAdjustSubtitleTiming(-0.1)
            showSettingsButton()
        }

        @objc private func increaseSubtitleTiming() {
            onAdjustSubtitleTiming(0.1)
            showSettingsButton()
        }

        private static func subtitleTimingText(_ offset: Double) -> String {
            if abs(offset) < 0.05 { return "0.0 sec" }
            return String(format: "%+.1f sec", offset)
        }

        private static func subtitleTimingAccessibilityValue(_ offset: Double) -> String {
            String(format: "%+.1f seconds", offset)
        }

        func updateQualities(
            _ qualities: [StreamQuality],
            selectedQuality: StreamQuality?
        ) {
            if settingsButton.configuration != nil,
               availableQualities == qualities,
               self.selectedQuality == selectedQuality {
                return
            }
            let discoveredQualities = availableQualities.isEmpty && !qualities.isEmpty
            availableQualities = qualities
            self.selectedQuality = selectedQuality
            rebuildSettingsMenu()
            if discoveredQualities { showSettingsButton() }
        }

        func updateSources(_ streams: [PlayableStream], selectedID: String?, automatic: Bool, isSearching: Bool,
                           onChanged: @escaping (String?, StreamQuality?) -> Void) {
            onSourceChanged = onChanged
            self.streams = streams
            selectedSourceID = selectedID
            automaticSource = automatic
            isSearchingForSources = isSearching
            let signature = streams.map { $0.id + $0.label + $0.qualities.map(\.title).joined() }.joined()
                + (selectedID ?? "") + String(automatic) + String(isSearching)
            guard signature != sourceMenuSignature else { return }
            sourceMenuSignature = signature
            rebuildSettingsMenu()
            showSettingsButton()
        }

        private func rebuildSettingsMenu() {
            let hasSettings = !streams.isEmpty || !availableQualities.isEmpty || subtitleTimingAvailable
            settingsButton.isHidden = !hasSettings
            guard hasSettings else {
                settingsButton.menu = nil
                return
            }

            var configuration = UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.image = UIImage(systemName: "ellipsis.circle.fill")
            configuration.baseForegroundColor = .white
            configuration.background.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            settingsButton.configuration = configuration

            settingsButton.accessibilityLabel = "Playback settings"
            let languageName = AppSetupStore.activePlaybackLanguageGroup.title
            let accessibilitySource: String

            if automaticSource {
                accessibilitySource = "Automatic · \(languageName)"
            } else if let selectedSourceID,
                      let stream = streams.first(
                        where: { $0.id == selectedSourceID }
                      ) {
                accessibilitySource =
                    stream.candidate.providerName
            } else {
                accessibilitySource = "Automatic · \(languageName)"
            }

            settingsButton.accessibilityValue =
                "\(accessibilitySource), \(selectedQuality?.title ?? "Auto quality")"
            var sections: [UIMenuElement] = []
            if !streams.isEmpty {
                let activeStream = selectedSourceID.flatMap { id in
                    streams.first { $0.id == id }
                }

                let activeSourceName = activeStream?.candidate.providerName
                    ?? "Unknown source"

                let activeQualityText = selectedQuality?.title
                    ?? activeStream?.candidate.displayMetadata?.quality
                    ?? "Auto"

                let automaticSubtitle: String

                if automaticSource {
                    automaticSubtitle =
                        "\(languageName) · Playing: \(activeSourceName) · \(activeQualityText)"
                } else {
                    automaticSubtitle = "Best \(languageName.lowercased()) source automatically"
                }

                var sources: [UIMenuElement] = [
                    UIAction(
                        title: "Automatic",
                        subtitle: automaticSubtitle,
                        image: UIImage(systemName: "wand.and.stars"),
                        state: automaticSource ? .on : .off
                    ) { [weak self] _ in
                        self?.onSourceChanged?(nil, nil)
                    }
                ]

                for stream in streams {
                    let active = selectedSourceID == stream.id

                    let sourceName = stream.candidate.providerName

                    var metadata: [String] = []

                    if let quality = stream.candidate.displayMetadata?.quality {
                        metadata.append(quality)
                    }

                    if let container = stream.candidate.displayMetadata?.container {
                        metadata.append(container.uppercased())
                    }

                    if let size = stream.candidate.displayMetadata?.sizeBytes {
                        metadata.append(
                            ByteCountFormatter.string(
                                fromByteCount: size,
                                countStyle: .file
                            )
                        )
                    }

                    if active {
                        metadata.insert("Playing", at: 0)
                    }

                    let subtitle = metadata.isEmpty
                        ? stream.label
                        : metadata.joined(separator: " • ")

                    let qualities = active
                        ? availableQualities
                        : stream.qualities

                    if qualities.isEmpty {
                        sources.append(
                            UIAction(
                                title: sourceName,
                                subtitle: subtitle,
                                image: active
                                    ? UIImage(systemName: "play.fill")
                                    : UIImage(systemName: "play.circle"),
                                state: active && !automaticSource ? .on : .off
                            ) { [weak self] _ in
                                self?.onSourceChanged?(stream.id, nil)
                            }
                        )
                    } else {
                        let choices: [StreamQuality?] =
                            [nil]
                            + qualities
                                .reversed()
                                .map { Optional($0) }

                        let actions = choices.map { quality in
                            UIAction(
                                title: quality?.title ?? "Auto",
                                state:
                                    active
                                    && !automaticSource
                                    && quality == selectedQuality
                                        ? .on
                                        : .off
                            ) { [weak self] _ in
                                self?.onSourceChanged?(
                                    stream.id,
                                    quality
                                )
                            }
                        }

                        sources.append(
                            UIMenu(
                                title: sourceName,
                                subtitle: subtitle,
                                image: active
                                    ? UIImage(systemName: "play.fill")
                                    : UIImage(systemName: "play.circle"),
                                children: actions
                            )
                        )
                    }
                }

                if isSearchingForSources {
                    sources.append(
                        UIAction(
                            title: "Searching for more sources…",
                            subtitle: "New sources will appear automatically",
                            image: UIImage(systemName: "magnifyingglass"),
                            attributes: [.disabled]
                        ) { _ in }
                    )
                }

                sections.append(
                    UIMenu(
                        title: "Source & Quality",
                        image: UIImage(systemName: "video"),
                        children: sources
                    )
                )
            }

            if subtitleTimingAvailable {
                var subtitleActions: [UIMenuElement] = [
                    UIAction(
                        title: "Browse subtitle tracks",
                        subtitle: "Provider · language · sync",
                        image: UIImage(systemName: "list.bullet.rectangle")
                    ) { [weak self] _ in
                        self?.onOpenSubtitlePicker()
                    },
                    UIAction(
                        title: "Subtitle Sync Studio",
                        subtitle: "Fine-tune timing for this title",
                        image: UIImage(systemName: "captions.bubble")
                    ) { [weak self] _ in
                        self?.onOpenSubtitleSync()
                    },
                    UIAction(
                        title: "Nudge earlier (−0.1s)",
                        image: UIImage(systemName: "minus.circle")
                    ) { [weak self] _ in
                        self?.onAdjustSubtitleTiming(-0.1)
                    },
                    UIAction(
                        title: "Nudge later (+0.1s)",
                        image: UIImage(systemName: "plus.circle")
                    ) { [weak self] _ in
                        self?.onAdjustSubtitleTiming(0.1)
                    },
                ]
                sections.append(
                    UIMenu(
                        title: "Subtitles",
                        image: UIImage(systemName: "captions.bubble.fill"),
                        children: subtitleActions
                    )
                )
            } else {
                sections.append(
                    UIAction(
                        title: "Browse subtitle tracks",
                        subtitle: "CC list plus online catalogs",
                        image: UIImage(systemName: "list.bullet.rectangle")
                    ) { [weak self] _ in
                        self?.onOpenSubtitlePicker()
                    }
                )
            }

            settingsButton.menu = UIMenu(title: "Playback Settings", children: sections)
        }

        @objc private func playerTapped(_ gesture: UITapGestureRecognizer) {
            let buttonLocation = gesture.location(in: settingsButton)
            if !settingsButton.isHidden, settingsButton.bounds.contains(buttonLocation) {
                showSettingsButton()
                return
            }
            if let view = gesture.view {
                let location = gesture.location(in: view)
                if isTouchInChromeArea(location, in: view) { return }
                var hitView: UIView? = view.hitTest(location, with: nil)
                while let current = hitView {
                    if current === settingsButton || current === subtitleTimingControl {
                        showSettingsButton()
                        return
                    }
                    if current is UIControl {
                        return
                    }
                    hitView = current.superview
                }
            }
            settingsButton.alpha > 0.1 ? hideSettingsButton() : showSettingsButton()
        }

        @objc private func playerDoubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let player, let view = gesture.view else { return }
            let location = gesture.location(in: view)
            if isTouchInChromeArea(location, in: view) { return }
            let delta: Double = location.x < view.bounds.midX ? -10 : 10
            let current = player.currentTime().seconds
            guard current.isFinite else { return }
            let target = max(0, current + delta)
            player.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            showGestureFeedback(delta < 0 ? "−10s" : "+10s")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            showSettingsButton()
        }

        @objc private func playerPanned(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                if isTouchInChromeArea(location, in: view) {
                    panMode = nil
                    gesture.isEnabled = false
                    gesture.isEnabled = true
                    return
                }
                panStartLocation = location
                panMode = nil
                initialVolume = AVAudioSession.sharedInstance().outputVolume
                initialBrightness = UIScreen.main.brightness
            case .changed:
                if panMode == nil {
                    guard abs(translation.y) > abs(translation.x), abs(translation.y) > 12 else { return }
                    panMode = panStartLocation.x < view.bounds.midX ? .brightness : .volume
                }
                let delta = -translation.y / max(view.bounds.height, 1)
                switch panMode {
                case .volume:
                    let value = min(max(initialVolume + Float(delta), 0), 1)
                    setSystemVolume(value)
                    showGestureFeedback(String(format: "Volume %.0f%%", value * 100))
                case .brightness:
                    let value = min(max(initialBrightness + delta, 0), 1)
                    UIScreen.main.brightness = value
                    showGestureFeedback(String(format: "Brightness %.0f%%", value * 100))
                case .none:
                    break
                }
            case .ended, .cancelled, .failed:
                panMode = nil
                hideGestureFeedback()
            default:
                break
            }
        }

        private func isTouchInChromeArea(_ location: CGPoint, in view: UIView) -> Bool {
            let height = view.bounds.height
            let width = view.bounds.width
            guard height > 0, width > 0 else { return false }
            // Keep bottom transport / top system chrome for AVKit.
            let topBand = max(height * 0.12, view.safeAreaInsets.top + 56)
            if location.y > height * 0.78 { return true }
            if location.y < topBand { return true }
            // Punch out the ⋯ / timing controls so volume pans never fight the menu.
            if isTouchInReservedControls(location, in: view) { return true }
            return false
        }

        private func isTouchInReservedControls(_ location: CGPoint, in view: UIView) -> Bool {
            let inset: CGFloat = 16
            if !settingsButton.isHidden, settingsButton.alpha > 0.05 {
                let frame = settingsButton.convert(
                    settingsButton.bounds.insetBy(dx: -inset, dy: -inset),
                    to: view
                )
                if frame.contains(location) { return true }
            }
            if !subtitleTimingControl.isHidden, subtitleTimingControl.alpha > 0.05 {
                let frame = subtitleTimingControl.convert(
                    subtitleTimingControl.bounds.insetBy(dx: -inset, dy: -inset),
                    to: view
                )
                if frame.contains(location) { return true }
            }
            return false
        }

        private func setSystemVolume(_ value: Float) {
            let slider = systemVolumeHUDSuppressor.subviews.compactMap { $0 as? UISlider }.first
            slider?.value = value
        }

        private func showGestureFeedback(_ text: String) {
            gestureFeedbackLabel.text = "  \(text)  "
            UIView.animate(withDuration: 0.15) {
                self.gestureFeedbackLabel.alpha = 1
            }
        }

        private func hideGestureFeedback() {
            UIView.animate(withDuration: 0.25, delay: 0.35) {
                self.gestureFeedbackLabel.alpha = 0
            }
        }

        private func showSettingsButton() {
            guard !streams.isEmpty
                    || !availableQualities.isEmpty
                    || subtitleTimingAvailable else { return }
            settingsButton.isHidden = false
            hideTask?.cancel()
            UIView.animate(withDuration: 0.2) { [settingsButton] in
                settingsButton.alpha = 0.86
            }
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.hideSettingsButton()
            }
        }

        private func hideSettingsButton() {
            hideTask?.cancel()
            UIView.animate(withDuration: 0.2) { [settingsButton] in
                settingsButton.alpha = 0
            }
            UIView.animate(withDuration: 0.2) { [subtitleTimingControl] in
                subtitleTimingControl.alpha = 0
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Allow volume/brightness pans with the player, but don't fight scrubbing.
            if gestureRecognizer === panGestureRecognizer {
                return false
            }
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let view = gestureRecognizer.view else { return true }
            let location = touch.location(in: view)
            if gestureRecognizer === panGestureRecognizer || gestureRecognizer === doubleTapGestureRecognizer {
                if isTouchInChromeArea(location, in: view) { return false }
                var hit: UIView? = touch.view
                while let current = hit {
                    if current === settingsButton || current === subtitleTimingControl {
                        return false
                    }
                    hit = current.superview
                }
                return true
            }
            if let touched = touch.view, touched is UIControl {
                return false
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === panGestureRecognizer,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = pan.view else { return true }
            let velocity = pan.velocity(in: view)
            return abs(velocity.y) > abs(velocity.x)
        }

        func playerViewControllerWillEndFullScreenPresentation(
            _ playerViewController: AVPlayerViewController,
            withAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
        ) {
            // Restore portrait while the player still covers the presenting
            // screen. Waiting until PlayerScreen disappears lets the details
            // view briefly lay itself out using the player's landscape width.
            onWillDismiss()
            coordinator.animate(alongsideTransition: nil) { [onDismiss] _ in onDismiss() }
        }
    }
}
