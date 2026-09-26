//
//  SpotifyModels.swift
//  SpotifyNotch
//
//  Wire DTOs for the Spotify Web API plus the mappings onto the domain types
//  in CoreModels. Kept separate so the rest of the app never sees a snake_case
//  field or an optional-riddled response shape.
//
//  Everything here is defensively optional: Spotify omits fields for podcasts,
//  local files and relinked tracks, and a missing field must degrade rather
//  than throw.
//

import Foundation

// MARK: - Decoder

enum SpotifyWire {
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}

// MARK: - Shared DTOs

struct SpotifyImageDTO: Decodable, Sendable {
    let url: String?
    let width: Int?
    let height: Int?
}

struct SpotifyArtistDTO: Decodable, Sendable {
    let name: String?
}

struct SpotifyAlbumDTO: Decodable, Sendable {
    let name: String?
    let images: [SpotifyImageDTO]?
}

/// Podcast container, present on `item` when `type == "episode"`.
struct SpotifyShowDTO: Decodable, Sendable {
    let name: String?
    let publisher: String?
    let images: [SpotifyImageDTO]?
}

/// A single decodable shape covering both `track` and `episode` items.
///
/// Episodes carry `show` + top-level `images` instead of `album` + `artists`,
/// and local files come back with a null `id`, so nothing here is required.
struct SpotifyPlayableItemDTO: Decodable, Sendable {
    let id: String?
    let uri: String?
    let name: String?
    let type: String?
    let durationMs: Int?
    let album: SpotifyAlbumDTO?
    let artists: [SpotifyArtistDTO]?
    let show: SpotifyShowDTO?
    let images: [SpotifyImageDTO]?
}

struct SpotifyDeviceDTO: Decodable, Sendable {
    let id: String?
    let name: String?
    let type: String?
    let isActive: Bool?
    let volumePercent: Int?
}

/// `/me/player` and `/me/player/currently-playing` share this shape; the
/// latter simply omits `device`.
struct SpotifyPlaybackDTO: Decodable, Sendable {
    let device: SpotifyDeviceDTO?
    let isPlaying: Bool?
    let progressMs: Int?
    let item: SpotifyPlayableItemDTO?
    let currentlyPlayingType: String?
    let timestamp: Int?
}

struct SpotifyDevicesDTO: Decodable, Sendable {
    let devices: [SpotifyDeviceDTO]?
}

struct SpotifyUserProfileDTO: Decodable, Sendable {
    let id: String?
    let displayName: String?
    let product: String?
}

/// `{"error": {"status": 404, "message": "..."}}` — the Web API's error body.
struct SpotifyErrorEnvelopeDTO: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        let status: Int?
        let message: String?
    }
    let error: Body?
}

// MARK: - Devices

/// Normalised device, used by the "no active device" recovery UI.
struct SpotifyDevice: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let kind: String
    let isActive: Bool
}

// MARK: - Artwork selection

extension SpotifyImageDTO {
    /// Spotify returns images largest-first (typically 640/300/64).
    /// The mini notch lobe renders around 300pt, so prefer the smallest
    /// image that is still at least `target` wide, else the largest available.
    static func artworkURL(from images: [SpotifyImageDTO]?, target: Int = 300) -> URL? {
        guard let images, !images.isEmpty else { return nil }

        let sized = images.compactMap { image -> (URL, Int)? in
            guard let raw = image.url, let url = URL(string: raw) else { return nil }
            return (url, image.width ?? image.height ?? 0)
        }
        guard !sized.isEmpty else { return nil }

        let atLeastTarget = sized.filter { $0.1 >= target }
        if let best = atLeastTarget.min(by: { $0.1 < $1.1 }) { return best.0 }
        return sized.max(by: { $0.1 < $1.1 })?.0
    }
}

// MARK: - Item mapping

extension SpotifyPlayableItemDTO {
    var isEpisode: Bool { type == "episode" }

    /// Never throws: an unrecognised item degrades to whatever fields exist,
    /// and only a completely nameless item maps to `nil`.
    func toTrackInfo() -> TrackInfo? {
        guard let name, !name.isEmpty else { return nil }

        let artist: String
        let album: String
        let artwork: URL?

        if isEpisode {
            let show = self.show?.name ?? self.show?.publisher ?? "Podcast"
            artist = show
            album = self.show?.name ?? ""
            artwork = SpotifyImageDTO.artworkURL(from: images ?? self.show?.images)
        } else {
            let names = (artists ?? []).compactMap(\.name).filter { !$0.isEmpty }
            artist = names.isEmpty ? "Unknown Artist" : names.joined(separator: ", ")
            album = self.album?.name ?? ""
            artwork = SpotifyImageDTO.artworkURL(from: self.album?.images ?? images)
        }

        return TrackInfo(
            id: stableIdentifier(name: name, artist: artist),
            title: name,
            artist: artist,
            album: album,
            artworkURL: artwork,
            duration: durationMs.map { TimeInterval($0) / 1000 } ?? 0
        )
    }

    /// Local files and some relinked items come back with a null `id`, so fall
    /// back to the URI and finally to a title/artist composite. `TrackInfo.id`
    /// drives artwork caching and palette extraction, so it must be stable
    /// across polls for the same track.
    private func stableIdentifier(name: String, artist: String) -> String {
        if let id, !id.isEmpty { return id }
        if let uri, !uri.isEmpty { return uri }
        return "local:\(artist)|\(name)"
    }
}

// MARK: - Playback mapping

extension SpotifyPlaybackDTO {
    func toSnapshot(capturedAt: Date = Date()) -> PlaybackSnapshot {
        let track = item?.toTrackInfo()
        let progress = TimeInterval(progressMs ?? 0) / 1000
        let duration = track?.duration ?? 0

        return PlaybackSnapshot(
            track: track,
            isPlaying: isPlaying ?? false,
            progress: duration > 0 ? min(max(0, progress), duration) : max(0, progress),
            deviceName: device?.name,
            // `/me/player` only returns a device at all when one is active;
            // `is_active` is still checked for the odd inactive payload.
            hasActiveDevice: device.map { $0.isActive ?? true } ?? false,
            capturedAt: capturedAt
        )
    }
}

extension SpotifyDeviceDTO {
    func toDevice() -> SpotifyDevice {
        let resolvedName = name ?? "Unknown Device"
        return SpotifyDevice(
            id: id ?? "unnamed:\(resolvedName)",
            name: resolvedName,
            kind: type ?? "Unknown",
            isActive: isActive ?? false
        )
    }
}

extension SpotifyUserProfileDTO {
    var accountTier: AccountTier {
        switch product?.lowercased() {
        case "premium": .premium
        // Spotify reports legacy plans as "open" and "free"; both are
        // non-premium and will 403 on transport control.
        case "free", "open": .free
        default: .unknown
        }
    }
}
