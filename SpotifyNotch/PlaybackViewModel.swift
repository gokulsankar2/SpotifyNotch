//
//  PlaybackViewModel.swift
//  SpotifyNotch
//
//  The bridge between the Spotify subsystem and the notch UI: owns the poll
//  loop, publishes playback state, and issues transport commands.
//
//  Spotify has no push mechanism for playback state, so this polls. Cadence
//  is driven by how visible the overlay actually is — there is no reason to
//  poll every three seconds when nothing is playing or the user is looking at
//  Spotify's own window.
//

import Combine
import Foundation
import OSLog

@MainActor
final class PlaybackViewModel: ObservableObject {

    // MARK: Published state

    @Published private(set) var snapshot: PlaybackSnapshot = .idle
    @Published private(set) var accountTier: AccountTier = .unknown
    @Published private(set) var isConnected = false

    /// A message worth putting in front of the user (free account, no active
    /// device). Transient network noise is deliberately not surfaced here.
    @Published private(set) var statusMessage: String?

    let progress: PlaybackProgressTimer
    let artwork: AlbumArtCache

    // MARK: Cadence

    private enum Cadence {
        /// Playing, overlay on screen.
        case active
        /// Paused but still showing, so track changes still matter.
        case visible
        /// Spotify is frontmost; the overlay is hidden but playback may change.
        case suppressed
        /// Nothing loaded at all.
        case idle

        var interval: TimeInterval {
            switch self {
            case .active: 3
            case .visible: 5
            case .suppressed: 8
            case .idle: 12
            }
        }
    }

    // MARK: Internals

    private let logger = Logger(subsystem: "com.Majestic-Banana.SpotifyNotch", category: "Playback")
    private let client: SpotifyAPIClient

    private var pollTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var isSuppressed = false
    private var lastPollAt: Date?
    /// Set when Spotify returns 429; the loop idles until it passes.
    private var backoffUntil: Date?
    private var consecutiveFailures = 0

    /// Minimum spacing between polls, so cadence changes cannot cause a burst.
    private static let minimumPollSpacing: TimeInterval = 1.0

    init(client: SpotifyAPIClient, artwork: AlbumArtCache = AlbumArtCache()) {
        self.client = client
        self.artwork = artwork
        self.progress = PlaybackProgressTimer()
    }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        isConnected = true
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        controlTask?.cancel()
        controlTask = nil
        isConnected = false
        snapshot = .idle
        accountTier = .unknown
        statusMessage = nil
        progress.stop()
        artwork.setCurrent(nil)
    }

    /// Told by `SpotifyFocusMonitor` that Spotify's own window came forward.
    func setSuppressed(_ suppressed: Bool) {
        guard isSuppressed != suppressed else { return }
        isSuppressed = suppressed
        restartPolling()
    }

    // MARK: - Poll loop

    private func currentCadence() -> Cadence {
        if isSuppressed { return .suppressed }
        guard snapshot.hasTrack else { return .idle }
        return snapshot.isPlaying ? .active : .visible
    }

    /// Cancels and restarts the loop so a cadence change takes effect now
    /// rather than after the previous (possibly 12 second) sleep expires.
    private func restartPolling() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    private func runPollLoop() async {
        while !Task.isCancelled {
            await waitUntilNextPoll()
            guard !Task.isCancelled else { return }
            await poll()
        }
    }

    /// Honours both the current cadence and any 429 backoff, and never polls
    /// twice within `minimumPollSpacing`.
    private func waitUntilNextPoll() async {
        let now = Date()
        var target = now

        if let lastPollAt {
            target = max(target, lastPollAt.addingTimeInterval(Self.minimumPollSpacing))
        }
        if let backoffUntil {
            target = max(target, backoffUntil)
        }
        if let lastPollAt, backoffUntil == nil {
            target = max(target, lastPollAt.addingTimeInterval(currentCadence().interval))
        }

        let delay = target.timeIntervalSince(now)
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func poll() async {
        lastPollAt = Date()
        do {
            let next = try await client.currentPlayback()
            apply(next)
            backoffUntil = nil
            consecutiveFailures = 0
        } catch let error as SpotifyError {
            logger.notice("Poll failed: \(error.message, privacy: .public)")
            handle(error)
        } catch {
            logger.notice("Poll failed: \(error.localizedDescription, privacy: .public)")
            handleTransientFailure()
        }
    }

    private func apply(_ next: PlaybackSnapshot) {
        let trackChanged = next.track?.id != snapshot.track?.id
        snapshot = next
        progress.update(with: next)

        if trackChanged {
            artwork.setCurrent(next.track?.artworkURL)
        }

        // Clear stale advisories once playback is healthy again.
        if next.hasActiveDevice, statusMessage != nil, accountTier != .free {
            statusMessage = nil
        }

        if accountTier == .unknown {
            Task { [weak self] in await self?.refreshAccountTier() }
        }
    }

    /// Internal rather than private so the tests can assert that an error
    /// never clears playback state out from under the overlay.
    func handle(_ error: SpotifyError) {
        switch error {
        case .rateLimited(let retryAfter):
            // Respect Retry-After exactly; Spotify's window is rolling and
            // hammering it again just extends the penalty.
            backoffUntil = Date().addingTimeInterval(retryAfter)
            logger.notice("Rate limited, backing off \(retryAfter, format: .fixed(precision: 0))s")
        case .notAuthenticated:
            // Deliberately does NOT tear the session down. Tearing down here
            // clears the snapshot, which hides the overlay for good even
            // though playback is still going — and a failed transport tap is
            // far too small a reason for that. Session teardown belongs to
            // the auth layer, which drops to `.signedOut` when a refresh
            // token is genuinely dead and stops polling through the
            // connection observer.
            statusMessage = error.message
            handleTransientFailure()
        case .premiumRequired, .noActiveDevice:
            statusMessage = error.message
        case .http, .transport, .decoding:
            handleTransientFailure()
        }
    }

    /// Network blips are common on a laptop that sleeps and roams between
    /// networks. Back off gently instead of surfacing noise to the user.
    private func handleTransientFailure() {
        consecutiveFailures += 1
        let penalty = min(pow(2, Double(consecutiveFailures)), 60)
        backoffUntil = Date().addingTimeInterval(penalty)
    }

    private func refreshAccountTier() async {
        guard let tier = try? await client.accountTier() else { return }
        accountTier = tier
        if tier == .free {
            statusMessage = SpotifyError.premiumRequired.message
        }
    }

#if DEBUG
    /// Drives the overlay from canned data, so the notch layout, colour
    /// extraction and hover transition can be verified without a Spotify
    /// account. Enabled with `SPOTIFYNOTCH_DEMO=1`.
    private(set) var isDemo = false
    private var demoIndex = 0

    /// Distinct artwork per track, so skipping also exercises palette
    /// extraction and the waveform re-tinting.
    private static let demoTracks: [TrackInfo] = [
        TrackInfo(
            id: "demo-1", title: "Midnight City", artist: "M83",
            album: "Hurry Up, We're Dreaming",
            artworkURL: URL(string: "https://picsum.photos/seed/notch-one/300"),
            duration: 241
        ),
        TrackInfo(
            id: "demo-2", title: "Nightcall", artist: "Kavinsky",
            album: "OutRun",
            artworkURL: URL(string: "https://picsum.photos/seed/notch-two/300"),
            duration: 258
        ),
        TrackInfo(
            id: "demo-3", title: "Teardrop", artist: "Massive Attack",
            album: "Mezzanine",
            artworkURL: URL(string: "https://picsum.photos/seed/notch-three/300"),
            duration: 330
        )
    ]

    func startDemo() {
        isDemo = true
        accountTier = .premium
        isConnected = true
        loadDemoTrack(at: 0, playing: true)
    }

    private func loadDemoTrack(at index: Int, playing: Bool) {
        let count = Self.demoTracks.count
        demoIndex = ((index % count) + count) % count
        let track = Self.demoTracks[demoIndex]
        snapshot = PlaybackSnapshot(
            track: track,
            isPlaying: playing,
            progress: 0,
            deviceName: "Demo Device",
            hasActiveDevice: true,
            capturedAt: Date()
        )
        progress.update(with: snapshot)
        artwork.setCurrent(track.artworkURL)
    }
#endif

    // MARK: - Transport

    func togglePlayPause() {
        let wasPlaying = snapshot.isPlaying
        // Optimistic: the poll is up to 3s away and the button must feel live.
        // Re-anchor to the interpolated position first, otherwise resuming
        // would replay from wherever the last poll happened to land.
        snapshot.progress = progress.progress
        snapshot.capturedAt = Date()
        snapshot.isPlaying = !wasPlaying
        progress.update(with: snapshot)
#if DEBUG
        if isDemo { return }
#endif
        runControl { client in
            if wasPlaying {
                try await client.pause()
            } else {
                try await client.play()
            }
        }
    }

    func next() {
#if DEBUG
        if isDemo {
            loadDemoTrack(at: demoIndex + 1, playing: snapshot.isPlaying)
            return
        }
#endif
        runControl { client in try await client.next() }
    }

    /// Standard semantics: restart the current track if more than three
    /// seconds in, otherwise go to the previous one.
    func previous() {
        let position = progress.progress
#if DEBUG
        if isDemo {
            // Same rule as the real client: restart if we are past the
            // threshold, otherwise step back a track.
            let restart = position > SpotifyAPIClient.restartThreshold
            loadDemoTrack(at: restart ? demoIndex : demoIndex - 1, playing: snapshot.isPlaying)
            return
        }
#endif
        runControl { client in
            try await client.previousOrRestart(progress: position)
        }
    }

    /// Runs one transport command at a time. Mashing Next replaces the
    /// in-flight command rather than queueing a pile of requests that would
    /// trip rate limiting and leave the UI lagging behind reality.
    private func runControl(
        _ body: @escaping @Sendable (SpotifyAPIClient) async throws -> Void
    ) {
        controlTask?.cancel()
        let client = self.client
        controlTask = Task { [weak self] in
            do {
                try await body(client)
                // Give Spotify a beat to settle before believing the next read.
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                await self?.poll()
            } catch let error as SpotifyError {
                self?.handle(error)
            } catch {
                // Cancelled by a newer command; nothing to report.
            }
        }
    }
}
