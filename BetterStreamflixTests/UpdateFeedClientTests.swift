import Foundation
import Testing

@Suite("Update check service")
struct UpdateFeedClientTests {
    @Test("Treats a newer GitHub release as an available update")
    func newerRelease() async {
        let transport = FeedRecordingTransport(data: Data(
            """
            {
              "tag_name": "v0.0.2",
              "name": "BetterStreamflix 0.0.2",
              "body": "## Changes\\n\\n- Newer build",
              "html_url": "https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases/tag/v0.0.2"
            }
            """.utf8
        ))
        let outcome = await UpdateCheckService(
            client: GitHubReleaseClient(client: transport)
        ).evaluate(currentVersion: "0.0.1", currentBuild: "5")

        guard case let .newerRelease(release) = outcome else {
            Issue.record("Expected newerRelease")
            return
        }
        #expect(release.tagName == "v0.0.2")
    }

    @Test("Falls back to the Releases CTA when the API is unavailable")
    func openReleasesFallback() async {
        let transport = FeedFailingTransport()
        let outcome = await UpdateCheckService(
            client: GitHubReleaseClient(client: transport)
        ).evaluate(currentVersion: "0.0.1", currentBuild: "5")

        #expect(outcome == .openReleases(version: "0.0.1", build: "5"))
    }

    @Test("Parses bookkeeping AppUpdateInfo JSON used by CI")
    func parsesBookkeepingJSON() throws {
        let data = Data(
            """
            {
              "version": "0.0.1",
              "build": "12",
              "releasedAt": "2026-09-24T08:00:00Z",
              "notes": "notes",
              "releasePageUrl": "https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases/tag/v0.0.1",
              "ipaAssetName": "BetterStreamflix-0.0.1-unsigned.ipa"
            }
            """.utf8
        )
        let info = try JSONDecoder().decode(AppUpdateInfo.self, from: data)
        #expect(info.version == "0.0.1")
        #expect(info.build == "12")
        #expect(info.tagName == "v0.0.1")
    }
}

private actor FeedRecordingTransport: HTTPClientProtocol {
    private let data: Data

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return HTTPResponse(data: data, response: response)
    }
}

private actor FeedFailingTransport: HTTPClientProtocol {
    func data(for request: URLRequest) async throws -> HTTPResponse {
        throw AppError.providerUnavailable("HTTP 404")
    }
}
