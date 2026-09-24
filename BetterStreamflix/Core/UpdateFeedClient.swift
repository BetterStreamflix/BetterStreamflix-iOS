import Foundation

struct AppUpdateInfo: Identifiable, Equatable, Sendable, Codable {
    var id: String { "\(version)-\(build)" }
    let version: String
    let build: String
    let releasedAt: String
    let notes: String
    let releasePageUrl: URL
    let ipaAssetName: String

    enum CodingKeys: String, CodingKey {
        case version
        case build
        case releasedAt
        case notes
        case releasePageUrl
        case ipaAssetName
    }

    var tagName: String {
        version.hasPrefix("v") ? version : "v\(version)"
    }

    var htmlURL: URL { releasePageUrl }

    var body: String { notes }
}

struct UpdateFeedClient: Sendable {
    private let feedURL: URL
    private let client: any HTTPClientProtocol

    init(
        feedURL: URL = SupportLinks.iosUpdateFeed,
        client: any HTTPClientProtocol = HTTPClient()
    ) {
        self.feedURL = feedURL
        self.client = client
    }

    func latestUpdate() async throws -> AppUpdateInfo {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadRevalidatingCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BetterStreamflix-iOS", forHTTPHeaderField: "User-Agent")

        let response = try await client.data(for: request)
        return try JSONDecoder().decode(AppUpdateInfo.self, from: response.data)
    }

    static func isNewer(update: AppUpdateInfo, than currentVersion: String, currentBuild: String) -> Bool {
        if VersionNumber.isNewer(update.version, than: currentVersion) {
            return true
        }
        if VersionNumber.isEqual(update.version, to: currentVersion) {
            return VersionNumber.isNewer(update.build, than: currentBuild)
        }
        return false
    }

    static func shouldOfferUpdate(
        update: AppUpdateInfo,
        currentVersion: String,
        currentBuild: String,
        skippedTagName: String
    ) -> Bool {
        guard isNewer(update: update, than: currentVersion, currentBuild: currentBuild) else {
            return false
        }
        guard !skippedTagName.isEmpty else { return true }

        let tag = update.tagName
        if let release = VersionNumber(tag), let skipped = VersionNumber(skippedTagName) {
            return release != skipped
        }
        return tag.compare(skippedTagName, options: [.caseInsensitive, .numeric]) != .orderedSame
    }
}

struct VersionNumber: Comparable, Equatable {
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

    static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        guard let left = VersionNumber(lhs), let right = VersionNumber(rhs) else {
            return lhs.compare(rhs, options: .numeric) == .orderedDescending
        }
        return left > right
    }

    static func isEqual(_ lhs: String, to rhs: String) -> Bool {
        guard let left = VersionNumber(lhs), let right = VersionNumber(rhs) else {
            return lhs.compare(rhs, options: [.caseInsensitive, .numeric]) == .orderedSame
        }
        return left == right
    }
}
