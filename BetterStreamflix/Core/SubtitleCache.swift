import CryptoKit
import Foundation

enum SubtitleCacheStatus: String, Sendable {
    case fresh
    case stale
}

struct CachedSubtitleRendition: Sendable {
    let rendition: HLSSubtitleRendition
    let status: SubtitleCacheStatus
}

actor SubtitleRenditionCache {
    static let shared = SubtitleRenditionCache()

    private struct StableKey: Codable, Hashable, Sendable {
        let contentID: String
        let providerID: String
        let subtitleKey: String
        let languageCode: String

        init(contentID: String, subtitle: SubtitleSource) {
            self.contentID = contentID
            providerID = subtitle.providerID.lowercased()
            subtitleKey = subtitle.syncKey
            languageCode = subtitle.canonicalLanguageCode ?? "und"
        }
    }

    private struct Payload: Codable, Sendable {
        let schemaVersion: Int
        let key: StableKey
        let providerName: String
        let label: String
        let isDefault: Bool
        let cues: [SubtitleCue]
        let createdAt: Date
        let refreshedAt: Date
        var lastAccessedAt: Date
        let etag: String?
        let lastModified: String?
    }

    private struct PendingRefresh {
        let key: StableKey
        let subtitle: SubtitleSource
        let loader: @Sendable () async throws -> [SubtitleCue]
    }

    private static let schemaVersion = 1
    private let fileManager: FileManager
    private let directory: URL
    private let freshInterval: TimeInterval
    private let sizeLimit: Int64
    private var memory: [StableKey: Payload] = [:]
    private var inFlight: [StableKey: Task<HLSSubtitleRendition, Error>] = [:]
    private var pendingRefreshes: [PendingRefresh] = []
    private var queuedRefreshKeys: Set<StableKey> = []
    private var activeRefreshCount = 0
    private let maximumConcurrentRefreshes = 6

    init(
        fileManager: FileManager = .default,
        directory: URL? = nil,
        freshInterval: TimeInterval = 30 * 24 * 60 * 60,
        sizeLimit: Int64 = 100 * 1_024 * 1_024
    ) {
        self.fileManager = fileManager
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directory = directory
            ?? caches.appending(path: "BetterStreamflix/Subtitles", directoryHint: .isDirectory)
        self.freshInterval = freshInterval
        self.sizeLimit = sizeLimit
    }

    func cachedRenditions(
        for contentID: String,
        now: Date = Date()
    ) -> [CachedSubtitleRendition] {
        ensureDirectory()
        var results: [CachedSubtitleRendition] = []
        let urls = (try? fileManager.contentsOfDirectory(
            at: contentDirectory(for: contentID),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for url in urls where url.pathExtension == "json" {
            guard let payload = decodedPayload(at: url) else {
                continue
            }
            guard payload.key.contentID == contentID else {
                try? fileManager.removeItem(at: url)
                continue
            }
            let accessed = touching(payload, at: url, now: now)
            memory[accessed.key] = accessed
            results.append(cachedRendition(from: accessed, now: now))
        }

        return results.sorted {
            if $0.rendition.subtitle.isDefault != $1.rendition.subtitle.isDefault {
                return $0.rendition.subtitle.isDefault
            }
            return $0.rendition.subtitle.label.localizedStandardCompare(
                $1.rendition.subtitle.label
            ) == .orderedAscending
        }
    }

    func lookup(
        contentID: String,
        subtitle: SubtitleSource,
        now: Date = Date()
    ) -> CachedSubtitleRendition? {
        let key = StableKey(contentID: contentID, subtitle: subtitle)
        if var payload = memory[key] {
            payload.lastAccessedAt = now
            memory[key] = payload
            let status = cacheStatus(for: payload, now: now)
            SubtitleDiagnostics.logger.info(
                "SUBTITLE PERF cache \(status.rawValue.uppercased(), privacy: .public) memory key=\(key.subtitleKey, privacy: .public)"
            )
            return cachedRendition(from: payload, now: now)
        }

        ensureDirectory()
        let url = fileURL(for: key)
        guard let payload = decodedPayload(at: url) else {
            SubtitleDiagnostics.logger.info(
                "SUBTITLE PERF cache MISS key=\(key.subtitleKey, privacy: .public)"
            )
            return nil
        }
        guard payload.key == key else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        let accessed = touching(payload, at: url, now: now)
        memory[key] = accessed
        let status = cacheStatus(for: accessed, now: now)
        SubtitleDiagnostics.logger.info(
            "SUBTITLE PERF cache \(status.rawValue.uppercased(), privacy: .public) disk key=\(key.subtitleKey, privacy: .public)"
        )
        return cachedRendition(from: accessed, now: now)
    }

    func rendition(
        contentID: String,
        subtitle: SubtitleSource,
        now: Date = Date(),
        loader: @escaping @Sendable () async throws -> [SubtitleCue]
    ) async throws -> HLSSubtitleRendition {
        let key = StableKey(contentID: contentID, subtitle: subtitle)
        if let cached = lookup(contentID: contentID, subtitle: subtitle, now: now) {
            if cached.status == .stale {
                startRefreshIfNeeded(key: key, subtitle: subtitle, loader: loader)
            }
            return cached.rendition
        }
        if let task = inFlight[key] {
            SubtitleDiagnostics.logger.info(
                "SUBTITLE PERF cache COALESCED key=\(key.subtitleKey, privacy: .public)"
            )
            return try await task.value
        }

        let task = Task<HLSSubtitleRendition, Error> {
            let cues = try await loader()
            try Task.checkCancellation()
            return HLSSubtitleRendition(subtitle: subtitle, cues: cues)
        }
        inFlight[key] = task
        do {
            let rendition = try await task.value
            inFlight[key] = nil
            store(rendition: rendition, contentID: contentID, now: now)
            return rendition
        } catch {
            inFlight[key] = nil
            throw error
        }
    }

    func store(
        rendition: HLSSubtitleRendition,
        contentID: String,
        now: Date = Date(),
        etag: String? = nil,
        lastModified: String? = nil
    ) {
        let key = StableKey(contentID: contentID, subtitle: rendition.subtitle)
        let payload = Payload(
            schemaVersion: Self.schemaVersion,
            key: key,
            providerName: rendition.subtitle.providerName,
            label: rendition.subtitle.label,
            isDefault: rendition.subtitle.isDefault,
            cues: rendition.cues,
            createdAt: memory[key]?.createdAt ?? now,
            refreshedAt: now,
            lastAccessedAt: now,
            etag: etag,
            lastModified: lastModified
        )
        ensureDirectory()
        try? fileManager.createDirectory(
            at: contentDirectory(for: contentID),
            withIntermediateDirectories: true
        )
        do {
            try encoded(payload).write(to: fileURL(for: key), options: .atomic)
            memory[key] = payload
            pruneIfNeeded()
        } catch {
            SubtitleDiagnostics.logger.error(
                "SUBTITLE PERF cache WRITE FAILED error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    func removeAll() {
        memory.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        pendingRefreshes.removeAll()
        queuedRefreshKeys.removeAll()
        activeRefreshCount = 0
        try? fileManager.removeItem(at: directory)
    }

    private func startRefreshIfNeeded(
        key: StableKey,
        subtitle: SubtitleSource,
        loader: @escaping @Sendable () async throws -> [SubtitleCue]
    ) {
        guard inFlight[key] == nil, !queuedRefreshKeys.contains(key) else { return }
        if activeRefreshCount >= maximumConcurrentRefreshes {
            queuedRefreshKeys.insert(key)
            pendingRefreshes.append(
                PendingRefresh(key: key, subtitle: subtitle, loader: loader)
            )
            return
        }
        launchRefresh(key: key, subtitle: subtitle, loader: loader)
    }

    private func launchRefresh(
        key: StableKey,
        subtitle: SubtitleSource,
        loader: @escaping @Sendable () async throws -> [SubtitleCue]
    ) {
        activeRefreshCount += 1
        SubtitleDiagnostics.logger.info(
            "SUBTITLE PERF cache REFRESH key=\(key.subtitleKey, privacy: .public)"
        )
        let task = Task<HLSSubtitleRendition, Error> {
            HLSSubtitleRendition(subtitle: subtitle, cues: try await loader())
        }
        inFlight[key] = task
        Task { [weak self] in
            do {
                let rendition = try await task.value
                await self?.completeRefresh(rendition, key: key)
            } catch {
                await self?.finishRefresh(key: key)
            }
        }
    }

    private func completeRefresh(_ rendition: HLSSubtitleRendition, key: StableKey) {
        guard inFlight[key] != nil else { return }
        inFlight[key] = nil
        store(rendition: rendition, contentID: key.contentID)
        finishRefreshSlot()
    }

    private func finishRefresh(key: StableKey) {
        guard inFlight[key] != nil else { return }
        inFlight[key] = nil
        finishRefreshSlot()
    }

    private func finishRefreshSlot() {
        activeRefreshCount = max(0, activeRefreshCount - 1)
        guard !pendingRefreshes.isEmpty else { return }
        let next = pendingRefreshes.removeFirst()
        queuedRefreshKeys.remove(next.key)
        launchRefresh(
            key: next.key,
            subtitle: next.subtitle,
            loader: next.loader
        )
    }

    private func cachedRendition(from payload: Payload, now: Date) -> CachedSubtitleRendition {
        let url = URL(string: "vela-cache://subtitle/\(digest(for: payload.key))")!
        let subtitle = SubtitleSource(
            id: payload.key.subtitleKey,
            providerID: payload.key.providerID,
            providerName: payload.providerName,
            label: payload.label,
            languageCode: payload.key.languageCode == "und" ? nil : payload.key.languageCode,
            url: url,
            isDefault: payload.isDefault,
            stableKey: payload.key.subtitleKey
        )
        return CachedSubtitleRendition(
            rendition: HLSSubtitleRendition(subtitle: subtitle, cues: payload.cues),
            status: cacheStatus(for: payload, now: now)
        )
    }

    private func cacheStatus(for payload: Payload, now: Date) -> SubtitleCacheStatus {
        now.timeIntervalSince(payload.refreshedAt) <= freshInterval ? .fresh : .stale
    }

    private func touching(_ original: Payload, at url: URL, now: Date) -> Payload {
        var payload = original
        payload.lastAccessedAt = now
        try? fileManager.setAttributes(
            [.modificationDate: now],
            ofItemAtPath: url.path
        )
        return payload
    }

    private func decodedPayload(at url: URL) -> Payload? {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(Payload.self, from: Data(contentsOf: url))
            guard payload.schemaVersion == Self.schemaVersion else {
                try? fileManager.removeItem(at: url)
                return nil
            }
            return payload
        } catch {
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    private func encoded(_ payload: Payload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func ensureDirectory() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: StableKey) -> URL {
        contentDirectory(for: key.contentID)
            .appending(path: "\(digest(for: key)).json")
    }

    private func contentDirectory(for contentID: String) -> URL {
        let digest = SHA256.hash(data: Data(contentID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: digest, directoryHint: .isDirectory)
    }

    private func digest(for key: StableKey) -> String {
        let raw = [key.contentID, key.providerID, key.subtitleKey, key.languageCode]
            .joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func pruneIfNeeded() {
        let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let urls = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "json" }
        var entries: [(URL, Int64, Date)] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                return nil
            }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > sizeLimit else { return }
        entries.sort { $0.2 < $1.2 }
        var removedAny = false
        for entry in entries where total > sizeLimit {
            try? fileManager.removeItem(at: entry.0)
            total -= entry.1
            removedAny = true
        }
        if removedAny { memory.removeAll() }
    }
}
