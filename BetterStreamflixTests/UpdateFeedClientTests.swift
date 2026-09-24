import Foundation
import Testing

@Suite("Public update feed")
struct UpdateFeedClientTests {
    @Test("Parses ios/latest.json fields")
    func parsesFeed() async throws {
        let transport = FeedRecordingTransport(data: Data(
            """
            {
              "version": "0.0.1",
              "build": "12",
              "releasedAt": "2026-09-24T08:00:00Z",
              "notes": "## BetterStreamflix 0.0.1\\n\\n- Premium update",
              "releasePageUrl": "https://github.com/BetterStreamflix/BetterStreamflix-iOS/releases/tag/v0.0.1",
              "ipaAssetName": "BetterStreamflix-0.0.1-unsigned.ipa"
            }
            """.utf8
        ))

        let update = try await UpdateFeedClient(
            feedURL: SupportLinks.iosUpdateFeed,
            client: transport
        ).latestUpdate()

        #expect(update.version == "0.0.1")
        #expect(update.build == "12")
        #expect(update.ipaAssetName.contains("unsigned.ipa"))
        #expect(update.tagName == "v0.0.1")
        let request = await transport.lastRequest
        #expect(request?.url?.absoluteString == SupportLinks.iosUpdateFeed.absoluteString)
    }

    @Test("Offers updates for newer version or same version with newer build")
    func comparesVersionAndBuild() {
        let newerVersion = AppUpdateInfo(
            version: "0.0.2",
            build: "1",
            releasedAt: "2026-01-01T00:00:00Z",
            notes: "notes",
            releasePageUrl: SupportLinks.githubRepository,
            ipaAssetName: "BetterStreamflix-0.0.2-unsigned.ipa"
        )
        let newerBuild = AppUpdateInfo(
            version: "0.0.1",
            build: "9",
            releasedAt: "2026-01-01T00:00:00Z",
            notes: "notes",
            releasePageUrl: SupportLinks.githubRepository,
            ipaAssetName: "BetterStreamflix-0.0.1-unsigned.ipa"
        )

        #expect(UpdateFeedClient.isNewer(update: newerVersion, than: "0.0.1", currentBuild: "99"))
        #expect(UpdateFeedClient.isNewer(update: newerBuild, than: "0.0.1", currentBuild: "8"))
        #expect(!UpdateFeedClient.isNewer(update: newerBuild, than: "0.0.1", currentBuild: "9"))
        #expect(UpdateFeedClient.shouldOfferUpdate(
            update: newerBuild,
            currentVersion: "0.0.1",
            currentBuild: "8",
            skippedTagName: ""
        ))
        #expect(!UpdateFeedClient.shouldOfferUpdate(
            update: newerBuild,
            currentVersion: "0.0.1",
            currentBuild: "8",
            skippedTagName: "v0.0.1"
        ))
    }
}

private actor FeedRecordingTransport: HTTPClientProtocol {
    private let data: Data
    private(set) var lastRequest: URLRequest?

    init(data: Data) {
        self.data = data
    }

    func data(for request: URLRequest) async throws -> HTTPResponse {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return HTTPResponse(data: data, response: response)
    }
}
