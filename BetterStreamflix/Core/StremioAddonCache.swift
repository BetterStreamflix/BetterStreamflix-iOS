import Foundation

/// Short-lived disk cache for Stremio manifests and catalog payloads (ETag-aware).
actor StremioAddonCache {
    static let shared = StremioAddonCache()

    private struct Entry: Codable {
        let data: Data
        let etag: String?
        let storedAt: Date
        let ttl: TimeInterval

        var isFresh: Bool {
            Date().timeIntervalSince(storedAt) < ttl
        }
    }

    private let directory: URL
    private var memory: [String: Entry] = [:]

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directory = base.appendingPathComponent("StremioAddonCache", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func cachedData(for key: String) -> (data: Data, etag: String?)? {
        if let entry = memory[key], entry.isFresh {
            return (entry.data, entry.etag)
        }
        let url = fileURL(for: key)
        guard let raw = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: raw),
              entry.isFresh else {
            return nil
        }
        memory[key] = entry
        return (entry.data, entry.etag)
    }

    func store(_ data: Data, etag: String?, for key: String, ttl: TimeInterval) {
        let entry = Entry(data: data, etag: etag, storedAt: Date(), ttl: ttl)
        memory[key] = entry
        if let encoded = try? JSONEncoder().encode(entry) {
            try? encoded.write(to: fileURL(for: key), options: .atomic)
        }
    }

    func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        let safe = key
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? String(key.hashValue)
        return directory.appendingPathComponent(safe + ".json")
    }
}

extension StremioAddonClient {
    /// Manifest TTL ~15 minutes; catalog ~3 minutes.
    static let manifestCacheTTL: TimeInterval = 15 * 60
    static let catalogCacheTTL: TimeInterval = 3 * 60
}
