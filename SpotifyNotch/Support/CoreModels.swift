//
//  CoreModels.swift
//  SpotifyNotch
//
//  Shared value types passed between the Spotify, Visual, Focus and Notch
//  subsystems. Everything here is a `Sendable` value type so it can cross
//  actor boundaries between the background API client and the main-actor UI.
//

import Foundation

// MARK: - Playback

/// The track Spotify reports as current, normalised away from the wire format.
struct TrackInfo: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let artworkURL: URL?
    let duration: TimeInterval

    init(
        id: String,
        title: String,
        artist: String,
        album: String,
        artworkURL: URL?,
        duration: TimeInterval
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.duration = duration
    }
}

/// A point-in-time reading of Spotify Connect playback state.
///
/// `capturedAt` is what lets `PlaybackProgressTimer` interpolate a smooth
/// progress value between the relatively slow (3-5s) API polls.
struct PlaybackSnapshot: Equatable, Sendable {
    var track: TrackInfo?
    var isPlaying: Bool
    var progress: TimeInterval
    var deviceName: String?
    var hasActiveDevice: Bool
    var capturedAt: Date

    init(
        track: TrackInfo? = nil,
        isPlaying: Bool = false,
        progress: TimeInterval = 0,
        deviceName: String? = nil,
        hasActiveDevice: Bool = false,
        capturedAt: Date = Date()
    ) {
        self.track = track
        self.isPlaying = isPlaying
        self.progress = progress
        self.deviceName = deviceName
        self.hasActiveDevice = hasActiveDevice
        self.capturedAt = capturedAt
    }

    /// Nothing loaded anywhere — the notch renders as bare hardware.
    static let idle = PlaybackSnapshot()

    /// True when there is a track loaded, whether or not it is currently
    /// advancing. A paused-but-loaded track still earns the mini presentation.
    var hasTrack: Bool { track != nil }
}

/// Spotify subscription level. Transport controls require `.premium`;
/// the Web API returns 403 for free accounts.
enum AccountTier: String, Sendable {
    case premium
    case free
    case unknown
}

// MARK: - Connection

enum ConnectionState: Equatable, Sendable {
    case signedOut
    case authorizing
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }
}

/// Failure modes the UI has to render differently, per the plan's
/// required empty/error states.
enum SpotifyError: Error, Equatable, Sendable {
    case notAuthenticated
    case premiumRequired
    case noActiveDevice
    case rateLimited(retryAfter: TimeInterval)
    case http(status: Int, message: String?)
    case transport(String)
    case decoding(String)

    /// Whether this is worth surfacing to the user versus silently retrying.
    var isUserFacing: Bool {
        switch self {
        case .premiumRequired, .noActiveDevice, .notAuthenticated: true
        case .rateLimited, .http, .transport, .decoding: false
        }
    }

    var message: String {
        switch self {
        case .notAuthenticated: "Not signed in to Spotify"
        case .premiumRequired: "Spotify Premium required"
        case .noActiveDevice: "No active Spotify device"
        case .rateLimited(let after): "Rate limited, retrying in \(Int(after))s"
        case .http(let status, let msg): msg ?? "Spotify error \(status)"
        case .transport(let msg): "Network error: \(msg)"
        case .decoding(let msg): "Unexpected response: \(msg)"
        }
    }
}

// MARK: - Presentation

/// What the notch overlay is currently showing.
enum NotchPresentation: Equatable, Sendable {
    /// Bare hardware notch: nothing playing, or Spotify itself is frontmost.
    case hidden
    /// Album-art lobe + waveform lobe, hugging the hardware notch.
    case mini
    /// Full card: art, metadata, progress, transport controls.
    case expanded
}

// MARK: - Visual

/// A colour sampled from album art. Kept as plain components rather than
/// `NSColor`/`Color` so it stays `Sendable` across the extraction actor.
struct RGBColor: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red.clamped01
        self.green = green.clamped01
        self.blue = blue.clamped01
    }

    /// Perceptual luminance (Rec. 709), used to keep the waveform legible
    /// against the black notch when album art is very dark.
    var luminance: Double {
        0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    /// Scales brightness while preserving hue, for building a gradient ramp.
    func adjustingBrightness(by factor: Double) -> RGBColor {
        RGBColor(red: red * factor, green: green * factor, blue: blue * factor)
    }
}

/// Dominant plus accent colours pulled from the current album art.
struct AlbumPalette: Equatable, Sendable {
    var primary: RGBColor
    var secondary: RGBColor
    var tertiary: RGBColor

    init(primary: RGBColor, secondary: RGBColor, tertiary: RGBColor) {
        self.primary = primary
        self.secondary = secondary
        self.tertiary = tertiary
    }

    /// Spotify green ramp, used before art loads or if extraction fails.
    static let fallback = AlbumPalette(
        primary: RGBColor(red: 0.11, green: 0.84, blue: 0.38),
        secondary: RGBColor(red: 0.07, green: 0.60, blue: 0.29),
        tertiary: RGBColor(red: 0.45, green: 0.93, blue: 0.62)
    )
}

// MARK: - Tempo (optional enhancement)

/// Beat timing for a track, when a provider can supply it.
struct TempoInfo: Equatable, Sendable {
    /// Beats per minute.
    var bpm: Double
    /// Optional beat grid, in seconds from track start.
    var beatTimes: [TimeInterval]?

    init(bpm: Double, beatTimes: [TimeInterval]? = nil) {
        self.bpm = bpm
        self.beatTimes = beatTimes
    }
}

/// Pluggable seam for real beat data.
///
/// Spotify deprecated Audio Features/Audio Analysis for apps created after
/// Nov 2024, so the shipping build uses `NullTempoProvider` and the waveform
/// runs its decorative animation. A third-party provider can be dropped in
/// here later without touching the view layer.
protocol TempoDataProvider: Sendable {
    func tempo(forTrackID id: String) async -> TempoInfo?
}

/// The shipping default: no real tempo data, decorative animation only.
struct NullTempoProvider: TempoDataProvider {
    init() {}
    func tempo(forTrackID id: String) async -> TempoInfo? { nil }
}

// MARK: - Helpers

extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self)) }
}
