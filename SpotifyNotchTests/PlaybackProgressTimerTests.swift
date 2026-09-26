//
//  PlaybackProgressTimerTests.swift
//  SpotifyNotchTests
//
//  The interpolation math that keeps the progress bar smooth between the
//  3-5 second Spotify polls.
//

import XCTest
@testable import SpotifyNotch

final class PlaybackProgressTimerTests: XCTestCase {

    private let anchorDate = Date(timeIntervalSince1970: 1_000_000)

    private func makeSnapshot(
        progress: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) -> PlaybackSnapshot {
        PlaybackSnapshot(
            track: TrackInfo(
                id: "track-1",
                title: "Title",
                artist: "Artist",
                album: "Album",
                artworkURL: nil,
                duration: duration
            ),
            isPlaying: isPlaying,
            progress: progress,
            deviceName: "Mac",
            hasActiveDevice: true,
            capturedAt: anchorDate
        )
    }

    func testAdvancesByWallClockWhilePlaying() {
        let snapshot = makeSnapshot(progress: 30, duration: 200, isPlaying: true)

        let result = PlaybackProgressTimer.interpolatedProgress(
            snapshot: snapshot,
            now: anchorDate.addingTimeInterval(4.5)
        )

        XCTAssertEqual(result, 34.5, accuracy: 0.0001)
    }

    func testFrozenWhilePaused() {
        let snapshot = makeSnapshot(progress: 30, duration: 200, isPlaying: false)

        let result = PlaybackProgressTimer.interpolatedProgress(
            snapshot: snapshot,
            now: anchorDate.addingTimeInterval(60)
        )

        XCTAssertEqual(result, 30, accuracy: 0.0001)
    }

    /// If a poll is missed near the end of a track, interpolation must not
    /// run the progress bar past 100%.
    func testClampsToTrackDuration() {
        let snapshot = makeSnapshot(progress: 195, duration: 200, isPlaying: true)

        let result = PlaybackProgressTimer.interpolatedProgress(
            snapshot: snapshot,
            now: anchorDate.addingTimeInterval(120)
        )

        XCTAssertEqual(result, 200, accuracy: 0.0001)
    }

    /// Clock changes (NTP correction, waking from sleep) can make `now`
    /// earlier than the anchor; progress must not go backwards or negative.
    func testNeverGoesNegativeWhenClockMovesBackwards() {
        let snapshot = makeSnapshot(progress: 30, duration: 200, isPlaying: true)

        let result = PlaybackProgressTimer.interpolatedProgress(
            snapshot: snapshot,
            now: anchorDate.addingTimeInterval(-500)
        )

        XCTAssertEqual(result, 30, accuracy: 0.0001)
    }

    /// Podcasts and unknown items can arrive with no duration; the math must
    /// still produce something sane rather than clamping everything to zero.
    func testUnknownDurationStillAdvances() {
        var snapshot = makeSnapshot(progress: 10, duration: 0, isPlaying: true)
        snapshot.track = nil

        let result = PlaybackProgressTimer.interpolatedProgress(
            snapshot: snapshot,
            now: anchorDate.addingTimeInterval(5)
        )

        XCTAssertEqual(result, 15, accuracy: 0.0001)
    }

    func testIdleSnapshotIsZero() {
        let result = PlaybackProgressTimer.interpolatedProgress(
            snapshot: .idle,
            now: anchorDate
        )

        XCTAssertEqual(result, 0, accuracy: 0.0001)
    }
}
