//
//  PlaybackViewModelTests.swift
//  SpotifyNotchTests
//
//  Regression cover for a bug where any Spotify error that surfaced from a
//  transport tap tore the session down, cleared the snapshot, and hid the
//  notch overlay permanently — with no way back short of relaunching.
//

import XCTest
@testable import SpotifyNotch

private struct FailingTokenProvider: AccessTokenProviding {
    func validAccessToken() async throws -> String { throw SpotifyError.notAuthenticated }
    func forceRefresh() async throws -> String { throw SpotifyError.notAuthenticated }
}

@MainActor
final class PlaybackViewModelTests: XCTestCase {

    private func makeViewModel() -> PlaybackViewModel {
        PlaybackViewModel(
            client: SpotifyAPIClient(
                tokenProvider: FailingTokenProvider(),
                session: StubURLProtocol.makeSession()
            )
        )
    }

    /// The overlay is driven by `snapshot.hasTrack`. Clearing the snapshot on
    /// an error is what made the notch vanish for good.
    func testAuthErrorKeepsTheTrackSoTheOverlayStaysUp() {
        let viewModel = makeViewModel()
        viewModel.startDemo()
        XCTAssertTrue(viewModel.snapshot.hasTrack)

        viewModel.handle(.notAuthenticated)

        XCTAssertTrue(
            viewModel.snapshot.hasTrack,
            "An auth error must not hide the overlay; the auth layer owns teardown"
        )
        XCTAssertNotNil(viewModel.statusMessage)
    }

    func testPremiumAndDeviceErrorsKeepTheOverlayUp() {
        for error in [SpotifyError.premiumRequired, .noActiveDevice] {
            let viewModel = makeViewModel()
            viewModel.startDemo()

            viewModel.handle(error)

            XCTAssertTrue(viewModel.snapshot.hasTrack, "\(error) must not hide the overlay")
            XCTAssertEqual(viewModel.statusMessage, error.message)
        }
    }

    func testRateLimitKeepsTheOverlayUp() {
        let viewModel = makeViewModel()
        viewModel.startDemo()

        viewModel.handle(.rateLimited(retryAfter: 5))

        XCTAssertTrue(viewModel.snapshot.hasTrack)
    }

    /// Explicit teardown is still allowed to clear everything.
    func testStopClearsState() {
        let viewModel = makeViewModel()
        viewModel.startDemo()

        viewModel.stop()

        XCTAssertFalse(viewModel.snapshot.hasTrack)
        XCTAssertFalse(viewModel.isConnected)
    }

    // MARK: Demo transport

    func testDemoNextAdvancesWithoutTouchingTheNetwork() {
        let viewModel = makeViewModel()
        viewModel.startDemo()
        let first = viewModel.snapshot.track?.id

        viewModel.next()

        XCTAssertNotEqual(viewModel.snapshot.track?.id, first)
        XCTAssertTrue(viewModel.snapshot.hasTrack)
        XCTAssertNil(viewModel.statusMessage, "Demo transport must not raise errors")
    }

    func testDemoPlayPauseToggles() {
        let viewModel = makeViewModel()
        viewModel.startDemo()
        XCTAssertTrue(viewModel.snapshot.isPlaying)

        viewModel.togglePlayPause()
        XCTAssertFalse(viewModel.snapshot.isPlaying)

        viewModel.togglePlayPause()
        XCTAssertTrue(viewModel.snapshot.isPlaying)
    }
}
