import Foundation

/// Bookkeeping model matching `ios/latest.json` written by CI into the private
/// BetterStreamflix-updates repository. The app does not fetch that private file.
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
}

enum AppUpdateOutcome: Equatable, Sendable {
    case newerRelease(GitHubRelease)
    case upToDate(version: String, build: String)
    /// Private-repo / offline path: show installed version and open Releases.
    case openReleases(version: String, build: String)
}

struct UpdateCheckService: Sendable {
    private let client: GitHubReleaseClient

    init(client: GitHubReleaseClient = GitHubReleaseClient()) {
        self.client = client
    }

    func evaluate(
        currentVersion: String,
        currentBuild: String
    ) async -> AppUpdateOutcome {
        do {
            let release = try await client.latestRelease()
            if GitHubReleaseClient.isNewer(tagName: release.tagName, than: currentVersion) {
                return .newerRelease(release)
            }
            return .upToDate(version: currentVersion, build: currentBuild)
        } catch {
            return .openReleases(version: currentVersion, build: currentBuild)
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
}

enum VersionNumber {
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        GitHubReleaseClient.isNewer(tagName: lhs, than: rhs)
    }
}
