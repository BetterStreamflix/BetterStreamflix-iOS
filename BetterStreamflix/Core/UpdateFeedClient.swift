import Foundation

/// Bookkeeping / public feed model matching `ios/latest.json` published by CI.
struct AppUpdateInfo: Identifiable, Equatable, Sendable, Codable {
    var id: String { "\(version)-\(build)" }
    let version: String
    let build: String
    let releasedAt: String
    let notes: String
    let releasePageUrl: URL
    let ipaAssetName: String

    var tagName: String {
        version.hasPrefix("v") ? version : "v\(version)"
    }

    /// Public raw feed the app reads without a token.
    static let publicFeedURL = URL(
        string: "https://raw.githubusercontent.com/BetterStreamflix/BetterStreamflix-update-feed/main/ios/latest.json"
    )!

    /// Public release history the in-app browser sheet reads without a token.
    static let publicReleasesURL = URL(
        string: "https://raw.githubusercontent.com/BetterStreamflix/BetterStreamflix-update-feed/main/ios/releases.json"
    )!
}

enum AppUpdateOutcome: Equatable, Sendable {
    case newerRelease(AppUpdateInfo)
    case upToDate(version: String, build: String)
    /// Feed unreachable — still offer a working path to the last-known Releases page.
    case unavailable(version: String, build: String)
}

struct PublicUpdateFeedClient: Sendable {
    private let client: any HTTPClientProtocol
    private let feedURL: URL
    private let releasesURL: URL

    init(
        client: any HTTPClientProtocol = HTTPClient(),
        feedURL: URL = AppUpdateInfo.publicFeedURL,
        releasesURL: URL = AppUpdateInfo.publicReleasesURL
    ) {
        self.client = client
        self.feedURL = feedURL
        self.releasesURL = releasesURL
    }

    func latest() async throws -> AppUpdateInfo {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BetterStreamflix-iOS", forHTTPHeaderField: "User-Agent")
        let response = try await client.data(for: request)
        return try JSONDecoder().decode(AppUpdateInfo.self, from: response.data)
    }

    func releases() async throws -> [AppUpdateInfo] {
        var request = URLRequest(url: releasesURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BetterStreamflix-iOS", forHTTPHeaderField: "User-Agent")
        let response = try await client.data(for: request)
        let decoded = try JSONDecoder().decode([AppUpdateInfo].self, from: response.data)
        return decoded.sorted { lhs, rhs in
            if let left = Version(lhs.tagName), let right = Version(rhs.tagName), left != right {
                return left > right
            }
            if lhs.version != rhs.version {
                return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
            }
            return (Int(lhs.build) ?? 0) > (Int(rhs.build) ?? 0)
        }
    }
}

struct UpdateCheckService: Sendable {
    private let feedClient: PublicUpdateFeedClient

    init(feedClient: PublicUpdateFeedClient = PublicUpdateFeedClient()) {
        self.feedClient = feedClient
    }

    /// Convenience for tests that still inject an HTTP transport via the feed client.
    init(client: any HTTPClientProtocol) {
        self.feedClient = PublicUpdateFeedClient(client: client)
    }

    func evaluate(
        currentVersion: String,
        currentBuild: String
    ) async -> AppUpdateOutcome {
        do {
            let info = try await feedClient.latest()
            if isNewer(info: info, currentVersion: currentVersion, currentBuild: currentBuild) {
                return .newerRelease(info)
            }
            return .upToDate(version: currentVersion, build: currentBuild)
        } catch {
            return .unavailable(version: currentVersion, build: currentBuild)
        }
    }

    static func shouldOfferUpdate(
        tagName: String,
        currentVersion: String,
        skippedTagName: String
    ) -> Bool {
        GitHubReleaseClient.shouldOfferUpdate(
            tagName: tagName,
            currentVersion: currentVersion,
            skippedTagName: skippedTagName
        )
    }

    static func shouldOfferUpdate(
        info: AppUpdateInfo,
        currentVersion: String,
        currentBuild: String,
        skippedTagName: String
    ) -> Bool {
        guard isNewer(info: info, currentVersion: currentVersion, currentBuild: currentBuild) else {
            return false
        }
        guard !skippedTagName.isEmpty else { return true }
        if let release = Version(info.tagName), let skipped = Version(skippedTagName) {
            return release != skipped
        }
        return info.tagName.compare(skippedTagName, options: [.caseInsensitive, .numeric]) != .orderedSame
    }

    private static func isNewer(
        info: AppUpdateInfo,
        currentVersion: String,
        currentBuild: String
    ) -> Bool {
        if GitHubReleaseClient.isNewer(tagName: info.tagName, than: currentVersion) {
            return true
        }
        // Same marketing version but a newer CI build number still counts as an update.
        if Version(info.tagName) == Version(currentVersion),
           let remoteBuild = Int(info.build),
           let localBuild = Int(currentBuild) {
            return remoteBuild > localBuild
        }
        return false
    }

    private func isNewer(
        info: AppUpdateInfo,
        currentVersion: String,
        currentBuild: String
    ) -> Bool {
        Self.isNewer(info: info, currentVersion: currentVersion, currentBuild: currentBuild)
    }
}

enum VersionNumber {
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        GitHubReleaseClient.isNewer(tagName: lhs, than: rhs)
    }
}

/// Shared with GitHubReleaseClient for tag/version comparisons.
struct Version: Comparable, Equatable {
    private let components: [Int]

    init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        value = String(value.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? "")

        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let parsed = parts.compactMap { Int($0) }
        guard !parsed.isEmpty, parsed.count == parts.count else { return nil }
        components = parsed
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
