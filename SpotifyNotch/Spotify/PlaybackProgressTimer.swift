//
//  PlaybackProgressTimer.swift
//  SpotifyNotch
//
//  Smooths the 3-5s playback poll into a per-frame progress value.
//
//  The API only tells us where the playhead was at `capturedAt`, so the
//  progress bar advances locally from that anchor and resyncs on every poll.
//  The arithmetic lives in `interpolatedProgress(snapshot:now:)` — pure and
//  unit tested — while this class only owns the tick loop and publishing.
//

import Combine
import Foundation

@MainActor
final class PlaybackProgressTimer: ObservableObject {
    /// Current playhead in seconds, interpolated between polls.
    @Published private(set) var progress: TimeInterval = 0
    /// Duration of the anchored track, or 0 when nothing is loaded.
    @Published private(set) var duration: TimeInterval = 0

    private(set) var snapshot: PlaybackSnapshot?
    private let tickInterval: TimeInterval
    private var tickTask: Task<Void, Never>?

    init(tickInterval: TimeInterval = 1.0 / 30.0) {
        self.tickInterval = max(1.0 / 120.0, tickInterval)
    }

    /// 0...1 for the progress bar; 0 when the duration is unknown.
    var fraction: Double {
        guard duration > 0 else { return 0 }
        return (progress / duration).clamped01
    }

    // MARK: - Driving

    /// Re-anchors on a fresh poll result. Starts ticking while playing and
    /// freezes the published value when paused.
    func update(with snapshot: PlaybackSnapshot) {
        self.snapshot = snapshot
        duration = snapshot.track?.duration ?? 0
        progress = Self.interpolatedProgress(snapshot: snapshot, now: Date())

        if snapshot.isPlaying && snapshot.track != nil {
            startTicking()
        } else {
            stopTicking()
        }
    }

    /// Stops the tick loop and clears the anchor.
    func stop() {
        stopTicking()
        snapshot = nil
        progress = 0
        duration = 0
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                if Task.isCancelled { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        guard let snapshot, snapshot.isPlaying else {
            stopTicking()
            return
        }
        progress = Self.interpolatedProgress(snapshot: snapshot, now: Date())
        if duration > 0 && progress >= duration {
            // Hold at the end until the next poll reports the new track.
            stopTicking()
        }
    }

    // MARK: - Interpolation

    /// Pure: where the playhead should be at `now`, given the anchor.
    /// Frozen when paused, never negative, never past the track duration.
    nonisolated static func interpolatedProgress(snapshot: PlaybackSnapshot, now: Date) -> TimeInterval {
        let duration = snapshot.track?.duration ?? 0
        let anchor = max(0, snapshot.progress)

        guard snapshot.isPlaying else {
            return duration > 0 ? min(anchor, duration) : anchor
        }

        let elapsed = max(0, now.timeIntervalSince(snapshot.capturedAt))
        let advanced = anchor + elapsed
        return duration > 0 ? min(advanced, duration) : advanced
    }
}
