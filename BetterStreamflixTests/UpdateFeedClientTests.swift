import Foundation
import Testing

@Suite("Update check service")
struct UpdateFeedClientTests {
    @Test("Treats a newer public feed version as an available update")
    func newerRelease() async {
        let transport = FeedRecordingTransport(data: Data(
            """
            {
              "version": "0.0.2",
              "build": "8",
              "releasedAt": "2026-09-24T08:00:00Z",
              "notes": "## Changes\\n\\n- Newer build",
              "releasePageUrl": "https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases/tag/v0.0.2",
              "ipaAssetName": "BetterStreamflix-0.0.2-unsigned.ipa"
            }
            """.utf8
        ))
        let outcome = await UpdateCheckService(client: transport)
            .evaluate(currentVersion: "0.0.1", currentBuild: "5")

        guard case let .newerRelease(info) = outcome else {
            Issue.record("Expected newerRelease")
            return
        }
        #expect(info.version == "0.0.2")
        #expect(info.build == "8")
        #expect(info.ipaAssetName == "BetterStreamflix-0.0.2-unsigned.ipa")
    }

    @Test("Treats a newer build at the same version as an available update")
    func newerBuildSameVersion() async {
        let transport = FeedRecordingTransport(data: Data(
            """
            {
              "version": "0.0.5",
              "build": "12",
              "releasedAt": "2026-09-24T08:00:00Z",
              "notes": "build bump",
              "releasePageUrl": "https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases/tag/v0.0.5",
              "ipaAssetName": "BetterStreamflix-0.0.5-unsigned.ipa"
            }
            """.utf8
        ))
        let outcome = await UpdateCheckService(client: transport)
            .evaluate(currentVersion: "0.0.5", currentBuild: "11")

        guard case .newerRelease = outcome else {
            Issue.record("Expected newerRelease for build bump")
            return
        }
    }

    @Test("Reports up to date when the feed matches the installed build")
    func upToDate() async {
        let transport = FeedRecordingTransport(data: Data(
            """
            {
              "version": "0.0.5",
              "build": "11",
              "releasedAt": "2026-09-24T08:00:00Z",
              "notes": "notes",
              "releasePageUrl": "https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases/tag/v0.0.5",
              "ipaAssetName": "BetterStreamflix-0.0.5-unsigned.ipa"
            }
            """.utf8
        ))
        let outcome = await UpdateCheckService(client: transport)
            .evaluate(currentVersion: "0.0.5", currentBuild: "11")
        #expect(outcome == .upToDate(version: "0.0.5", build: "11"))
    }

    @Test("Falls back when the public feed is unavailable")
    func unavailableFallback() async {
        let transport = FeedFailingTransport()
        let outcome = await UpdateCheckService(client: transport)
            .evaluate(currentVersion: "0.0.1", currentBuild: "5")

        #expect(outcome == .unavailable(version: "0.0.1", build: "5"))
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
        #expect(AppUpdateInfo.publicFeedURL.host == "raw.githubusercontent.com")
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
