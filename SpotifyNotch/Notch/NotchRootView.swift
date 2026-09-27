//
//  NotchRootView.swift
//  SpotifyNotch
//
//  The overlay's SwiftUI content. Renders the mini lobes and the expanded
//  card inside one morphing `NotchShape`, so the transition reads as the
//  hardware notch growing rather than a card fading in over it.
//

import SwiftUI

struct NotchRootView: View {

    @ObservedObject var notch: NotchWindowController
    @ObservedObject var playback: PlaybackViewModel
    @ObservedObject var artwork: AlbumArtCache
    @ObservedObject var progress: PlaybackProgressTimer

    var body: some View {
        // Pinned to the top of the panel, which is itself flush with the
        // top screen edge, so the shape's square top meets the bezel exactly.
        VStack(spacing: 0) {
            if let geometry = notch.geometry {
                shell(geometry: geometry)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Shell

    private func shell(geometry: NotchGeometry) -> some View {
        let presentation = notch.presentation

        // Hidden collapses to the hardware notch's exact dimensions rather
        // than disappearing outright: a black shape the size of the cutout is
        // indistinguishable from bare hardware, so the overlay appears to
        // retract into the notch. The panel is ordered out once this settles.
        let size: CGSize = switch presentation {
        case .hidden: CGSize(width: geometry.notchWidth, height: geometry.notchHeight)
        case .mini: geometry.miniRect.size
        case .expanded: geometry.expandedRect.size
        }

        return ZStack(alignment: .top) {
            NotchShape(
                topRadius: NotchMetrics.topCornerRadius,
                bottomRadius: presentation == .expanded
                    ? NotchMetrics.expandedBottomRadius
                    : NotchMetrics.bottomCornerRadius
            )
            .fill(.black)

            switch presentation {
            case .hidden:
                Color.clear
            case .mini:
                miniContent(geometry: geometry).transition(.opacity)
            case .expanded:
                expandedContent(geometry: geometry).transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    // MARK: - Mini

    /// Album art and waveform sit in the lobes either side of the physical
    /// notch, which is a hardware cutout with no pixels to draw into.
    private func miniContent(geometry: NotchGeometry) -> some View {
        HStack(spacing: 0) {
            ZStack {
                if let image = artwork.currentImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(artwork.currentPalette.primary).opacity(0.35))
                        .frame(width: 20, height: 20)
                }
            }
            .frame(width: NotchMetrics.miniLobeWidth)

            // The hardware notch itself.
            Spacer(minLength: 0)
                .frame(width: geometry.notchWidth)

            WaveformView(
                palette: artwork.currentPalette,
                isPlaying: playback.snapshot.isPlaying,
                playbackPosition: progress.progress
            )
            .frame(width: 34, height: 14)
            .frame(width: NotchMetrics.miniLobeWidth)
        }
        .frame(height: geometry.notchHeight)
    }

    // MARK: - Expanded

    /// Laid out for a wide, shallow card: artwork and text share one band,
    /// with the progress bar tucked under the text rather than on its own
    /// row, leaving the transport controls a full-width row at the bottom.
    private func expandedContent(geometry: NotchGeometry) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                albumArt

                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.snapshot.track?.title ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(secondaryLine)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    progressBar
                }
                .frame(height: Self.artworkSize)
            }

            // Absorbs leftover height so the transport row can never be the
            // thing that overflows and gets clipped.
            Spacer(minLength: 0)

            transportControls
        }
        // Kept clear of the 44pt lower corners, which curve well inside the
        // card's full width.
        .padding(.horizontal, NotchMetrics.topCornerRadius + 20)
        .padding(.top, geometry.notchHeight + 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private static let artworkSize: CGFloat = 64

    private var albumArt: some View {
        Group {
            if let image = artwork.currentImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(artwork.currentPalette.primary).opacity(0.3)
            }
        }
        .frame(width: Self.artworkSize, height: Self.artworkSize)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    /// One line has to carry artist, device and any advisory, since the
    /// shallower card has no room for a third row of text. A free account or
    /// a missing Connect device matters more than the artist name does.
    private var secondaryLine: String {
        if let status = playback.statusMessage { return status }
        let artist = playback.snapshot.track?.artist ?? ""
        guard let device = playback.snapshot.deviceName, !device.isEmpty else { return artist }
        return artist.isEmpty ? device : "\(artist) · \(device)"
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.15))
                    Capsule()
                        .fill(Color(artwork.currentPalette.primary))
                        .frame(width: max(0, proxy.size.width * progress.fraction))
                }
            }
            .frame(height: 3)

            HStack {
                Text(Self.timestamp(progress.progress))
                Spacer()
                Text(Self.timestamp(progress.duration))
            }
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var transportControls: some View {
        HStack(spacing: 26) {
            Spacer(minLength: 0)

            controlButton("backward.fill", size: 13) { playback.previous() }

            controlButton(
                playback.snapshot.isPlaying ? "pause.fill" : "play.fill",
                size: 17
            ) {
                playback.togglePlayPause()
            }

            controlButton("forward.fill", size: 13) { playback.next() }

            Spacer(minLength: 0)
        }
    }

    private func controlButton(
        _ symbol: String,
        size: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white.opacity(controlsEnabled ? 0.92 : 0.3))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!controlsEnabled)
    }

    /// Spotify rejects playback modification without Premium, so the controls
    /// are shown greyed rather than silently failing on tap.
    private var controlsEnabled: Bool {
        playback.accountTier != .free
    }

    // MARK: - Helpers

    private static func timestamp(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
