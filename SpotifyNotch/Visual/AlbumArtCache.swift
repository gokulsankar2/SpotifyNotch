//
//  AlbumArtCache.swift
//  SpotifyNotch
//
//  Main-actor artwork store: one download per URL, a bounded in-memory NSImage
//  cache, and the matching AlbumPalette from AlbumColorExtractor. Duplicate
//  in-flight requests share a single task, and results that land after the
//  track has moved on are dropped instead of flashing on screen.
//

import AppKit
import Combine
import Foundation

// MARK: - Storage types

/// Only the `Sendable` half of a fetch crosses back from the detached task;
/// `NSImage` is built on the main actor from these bytes.
private struct ArtworkPayload: Sendable {
    let data: Data
    let palette: AlbumPalette
}

private final class ArtworkEntry {
    let image: NSImage
    let palette: AlbumPalette

    init(image: NSImage, palette: AlbumPalette) {
        self.image = image
        self.palette = palette
    }
}

// MARK: - Cache

@MainActor
final class AlbumArtCache: ObservableObject {

    // MARK: Published state

    @Published private(set) var currentImage: NSImage?
    @Published private(set) var currentPalette: AlbumPalette = .fallback
    @Published private(set) var currentURL: URL?

    // MARK: Stored state

    private let session: URLSession
    private let extractor: AlbumColorExtractor
    private let cache = NSCache<NSURL, ArtworkEntry>()
    private var inFlight: [URL: Task<ArtworkPayload?, Never>] = [:]
    private var presentation: Task<Void, Never>?
    private var generation: UInt64 = 0

    /// Holding down Next fires a new artwork URL every few hundred ms. Waiting
    /// this long before spending a request keeps skip-spam off the network.
    private static let settleDelay = Duration.milliseconds(140)

    init(session: URLSession = .shared,
         extractor: AlbumColorExtractor = .shared,
         countLimit: Int = 24,
         byteLimit: Int = 24 * 1024 * 1024) {
        self.session = session
        self.extractor = extractor
        cache.countLimit = countLimit
        cache.totalCostLimit = byteLimit
    }

    // MARK: - Loading

    /// Returns the cached artwork for `url`, downloading and extracting it if
    /// this is the first request. Concurrent callers for the same URL share one
    /// download. Returns `nil` on any transport or decode failure.
    @discardableResult
    func load(_ url: URL) async -> (image: NSImage, palette: AlbumPalette)? {
        let key = url as NSURL
        if let hit = cache.object(forKey: key) {
            return (hit.image, hit.palette)
        }

        let task: Task<ArtworkPayload?, Never>
        if let existing = inFlight[url] {
            task = existing
        } else {
            let session = self.session
            let extractor = self.extractor
            task = Task.detached(priority: .userInitiated) {
                await AlbumArtCache.fetch(url, session: session, extractor: extractor)
            }
            inFlight[url] = task
        }

        let payload = await task.value
        if inFlight[url] == task {
            inFlight[url] = nil
        }

        guard let payload, let image = NSImage(data: payload.data) else { return nil }
        let entry = ArtworkEntry(image: image, palette: payload.palette)
        cache.setObject(entry, forKey: key, cost: payload.data.count)
        return (image, payload.palette)
    }

    /// Points the published state at `url`. Any load still running for a
    /// previous track is abandoned, so a burst of skips only ever paints the
    /// artwork the user actually landed on.
    func setCurrent(_ url: URL?) {
        generation &+= 1
        let token = generation
        presentation?.cancel()
        presentation = nil

        guard let url else {
            currentURL = nil
            currentImage = nil
            currentPalette = .fallback
            return
        }

        guard url != currentURL || currentImage == nil else { return }
        currentURL = url

        if let hit = cache.object(forKey: url as NSURL) {
            currentImage = hit.image
            currentPalette = hit.palette
            return
        }

        // The previous artwork stays on screen until the new one is ready,
        // rather than blanking the lobe mid-fetch.
        presentation = Task { [weak self] in
            try? await Task.sleep(for: AlbumArtCache.settleDelay)
            guard !Task.isCancelled, let self else { return }
            guard let result = await self.load(url) else { return }
            guard !Task.isCancelled, self.generation == token else { return }
            self.currentImage = result.image
            self.currentPalette = result.palette
        }
    }

    /// Warms the cache without touching the published state — useful for the
    /// next track in the queue.
    func prefetch(_ url: URL) {
        guard cache.object(forKey: url as NSURL) == nil, inFlight[url] == nil else { return }
        Task { _ = await self.load(url) }
    }

    func removeAll() {
        presentation?.cancel()
        presentation = nil
        for task in inFlight.values {
            task.cancel()
        }
        inFlight.removeAll()
        cache.removeAllObjects()
        currentURL = nil
        currentImage = nil
        currentPalette = .fallback
    }

    // MARK: - Fetch

    private nonisolated static func fetch(_ url: URL,
                                          session: URLSession,
                                          extractor: AlbumColorExtractor) async -> ArtworkPayload? {
        guard let result = try? await session.data(from: url) else { return nil }
        if let response = result.1 as? HTTPURLResponse,
           !(200..<300).contains(response.statusCode) {
            return nil
        }
        guard !result.0.isEmpty else { return nil }

        let palette = await extractor.palette(from: result.0)
        return ArtworkPayload(data: result.0, palette: palette)
    }
}
