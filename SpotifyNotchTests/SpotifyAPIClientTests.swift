//
//  SpotifyAPIClientTests.swift
//  SpotifyNotchTests
//
//  Response parsing and the HTTP status -> SpotifyError mapping that the
//  UI's empty/error states depend on.
//

import XCTest
@testable import SpotifyNotch

// MARK: - Token stub

private struct StubTokenProvider: AccessTokenProviding {
    var token: String = "stub-access-token"
    func validAccessToken() async throws -> String { token }
    func forceRefresh() async throws -> String { token }
}

// MARK: - Tests

final class SpotifyAPIClientTests: XCTestCase {

    private var client: SpotifyAPIClient!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        client = SpotifyAPIClient(
            tokenProvider: StubTokenProvider(),
            session: StubURLProtocol.makeSession()
        )
    }

    override func tearDown() {
        StubURLProtocol.reset()
        client = nil
        super.tearDown()
    }

    // MARK: Parsing

    func testParsesPlayingTrack() async throws {
        StubURLProtocol.enqueue(.json(Fixtures.playingTrack))

        let snapshot = try await client.currentPlayback()

        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertEqual(snapshot.track?.id, "6rqhFgbbKwnb9MLmUQDhG6")
        XCTAssertEqual(snapshot.track?.title, "Test Track")
        XCTAssertEqual(snapshot.track?.album, "Test Album")
        XCTAssertEqual(snapshot.progress, 42.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.track?.duration ?? 0, 210.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.deviceName, "Gokul's MacBook Pro")
        XCTAssertTrue(snapshot.hasActiveDevice)
    }

    /// Multiple artists are joined, matching how Spotify's own UI reads.
    func testJoinsMultipleArtists() async throws {
        StubURLProtocol.enqueue(.json(Fixtures.playingTrack))

        let snapshot = try await client.currentPlayback()

        XCTAssertEqual(snapshot.track?.artist, "First Artist, Second Artist")
    }

    /// The mini lobe renders art at 20pt, so the ~300px image is the right
    /// trade-off — not the 640px one, and not the 64px one.
    func testPicksMidSizedArtwork() async throws {
        StubURLProtocol.enqueue(.json(Fixtures.playingTrack))

        let snapshot = try await client.currentPlayback()

        XCTAssertEqual(
            snapshot.track?.artworkURL?.absoluteString,
            "https://i.scdn.co/image/medium300"
        )
    }

    /// 204 means nothing is playing anywhere. That is a normal idle state,
    /// not an error, and must not put the UI into a failure mode.
    func testNoContentIsIdleNotAnError() async throws {
        StubURLProtocol.enqueue(.init(statusCode: 204))

        let snapshot = try await client.currentPlayback()

        XCTAssertFalse(snapshot.hasTrack)
        XCTAssertFalse(snapshot.isPlaying)
    }

    func testNullItemIsHandled() async throws {
        StubURLProtocol.enqueue(.json(Fixtures.nullItem))

        let snapshot = try await client.currentPlayback()

        XCTAssertFalse(snapshot.hasTrack)
    }

    /// Podcast episodes have a different item shape. The notch does not
    /// support them, but they must degrade rather than throw.
    func testEpisodeDoesNotThrow() async throws {
        StubURLProtocol.enqueue(.json(Fixtures.episode))

        let snapshot = try await client.currentPlayback()

        XCTAssertTrue(snapshot.isPlaying)
    }

    func testParsesAccountTier() async throws {
        StubURLProtocol.enqueue(.json(#"{"product":"premium","id":"u"}"#))
        let tier = try await client.accountTier()
        XCTAssertEqual(tier, .premium)
    }

    func testParsesFreeAccountTier() async throws {
        StubURLProtocol.enqueue(.json(#"{"product":"free","id":"u"}"#))
        let tier = try await client.accountTier()
        XCTAssertEqual(tier, .free)
    }

    // MARK: Error mapping

    func testForbiddenMapsToPremiumRequired() async {
        StubURLProtocol.enqueue(.json(Fixtures.errorBody(403), statusCode: 403))

        await assertThrows(.premiumRequired) { try await self.client.play() }
    }

    func testNotFoundMapsToNoActiveDevice() async {
        StubURLProtocol.enqueue(.json(Fixtures.errorBody(404), statusCode: 404))

        await assertThrows(.noActiveDevice) { try await self.client.next() }
    }

    func testTooManyRequestsCarriesRetryAfter() async {
        StubURLProtocol.enqueue(
            .init(statusCode: 429, headers: ["Retry-After": "7"])
        )

        await assertThrows(.rateLimited(retryAfter: 7)) {
            _ = try await self.client.currentPlayback()
        }
    }

    /// A 401 should transparently refresh and retry exactly once before
    /// giving up, so a stale access token never surfaces to the user.
    func testUnauthorizedRefreshesAndRetriesOnce() async throws {
        StubURLProtocol.enqueue(.init(statusCode: 401))
        StubURLProtocol.enqueue(.json(Fixtures.playingTrack))

        let snapshot = try await client.currentPlayback()

        XCTAssertEqual(snapshot.track?.title, "Test Track")
        XCTAssertEqual(StubURLProtocol.requests.count, 2, "Expected one retry")
    }

    func testRepeatedUnauthorizedGivesUp() async {
        StubURLProtocol.enqueue(.init(statusCode: 401))
        StubURLProtocol.enqueue(.init(statusCode: 401))

        await assertThrows(.notAuthenticated) {
            _ = try await self.client.currentPlayback()
        }
    }

    // MARK: Transport semantics

    /// Past the 3s threshold, Previous restarts the current track.
    func testPreviousRestartsWhenPastThreshold() async throws {
        StubURLProtocol.enqueue(.init(statusCode: 204))

        try await client.previousOrRestart(progress: 12)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertTrue(
            request.url?.path.contains("seek") == true,
            "Expected a seek, got \(request.url?.path ?? "nil")"
        )
    }

    /// Within the first 3s, it skips to the previous track instead.
    func testPreviousSkipsWhenNearStart() async throws {
        StubURLProtocol.enqueue(.init(statusCode: 204))

        try await client.previousOrRestart(progress: 1.2)

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertTrue(
            request.url?.path.contains("previous") == true,
            "Expected a previous, got \(request.url?.path ?? "nil")"
        )
    }

    func testRequestsCarryBearerToken() async throws {
        StubURLProtocol.enqueue(.json(Fixtures.playingTrack))

        _ = try await client.currentPlayback()

        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer stub-access-token"
        )
    }

    // MARK: Helpers

    private func assertThrows(
        _ expected: SpotifyError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: @escaping () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("Expected \(expected) but nothing was thrown", file: file, line: line)
        } catch let error as SpotifyError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }
}

// MARK: - Fixtures

private enum Fixtures {
    static let playingTrack = """
    {
      "is_playing": true,
      "progress_ms": 42500,
      "device": { "id": "d1", "name": "Gokul's MacBook Pro", "is_active": true, "type": "Computer" },
      "item": {
        "type": "track",
        "id": "6rqhFgbbKwnb9MLmUQDhG6",
        "name": "Test Track",
        "duration_ms": 210000,
        "artists": [ { "name": "First Artist" }, { "name": "Second Artist" } ],
        "album": {
          "name": "Test Album",
          "images": [
            { "url": "https://i.scdn.co/image/large640", "width": 640, "height": 640 },
            { "url": "https://i.scdn.co/image/medium300", "width": 300, "height": 300 },
            { "url": "https://i.scdn.co/image/small64", "width": 64, "height": 64 }
          ]
        }
      }
    }
    """

    static let nullItem = """
    { "is_playing": false, "progress_ms": 0, "item": null,
      "device": { "id": "d1", "name": "Phone", "is_active": true, "type": "Smartphone" } }
    """

    static let episode = """
    {
      "is_playing": true,
      "progress_ms": 1000,
      "device": { "id": "d1", "name": "Phone", "is_active": true, "type": "Smartphone" },
      "item": {
        "type": "episode",
        "id": "ep1",
        "name": "Some Episode",
        "duration_ms": 3600000,
        "show": { "name": "A Podcast" }
      }
    }
    """

    static func errorBody(_ status: Int) -> String {
        #"{"error":{"status":\#(status),"message":"stub"}}"#
    }
}
