//
//  WaveformView.swift
//  SpotifyNotch
//
//  The animated bar visualisation in the notch's right lobe. Decorative by
//  default — layered sine waves, explicitly NOT synced to audio — and
//  beat-driven when a TempoDataProvider supplies TempoInfo.
//

import SwiftUI

// MARK: - Frame state

/// Everything the draw pass needs, resolved once per frame outside the
/// `Canvas` closure so the renderer captures a plain value rather than the view.
private struct WaveformFrame: Sendable {
    var time: Double
    var envelope: Double
    var barCount: Int
    var gradient: Gradient
    /// `nil` in decorative mode; otherwise position within the current beat.
    var beatPhase: Double?
}

/// Anchors a polled track position to the timeline clock so tempo mode can
/// extrapolate between the (3-5s) playback polls.
private struct PositionAnchor {
    var position: TimeInterval
    var clock: Double
}

// MARK: - View

struct WaveformView: View {

    let palette: AlbumPalette
    let isPlaying: Bool
    /// `nil` selects decorative mode, which is the shipping default.
    let tempo: TempoInfo?
    /// Track position from the most recent poll. Only consulted to line the
    /// pulse up with `TempoInfo.beatTimes`.
    let playbackPosition: TimeInterval?
    let barCount: Int

    init(palette: AlbumPalette,
         isPlaying: Bool,
         tempo: TempoInfo? = nil,
         playbackPosition: TimeInterval? = nil,
         barCount: Int = 5) {
        self.palette = palette
        self.isPlaying = isPlaying
        self.tempo = tempo
        self.playbackPosition = playbackPosition
        self.barCount = min(7, max(4, barCount))
    }

    // MARK: Tuning

    /// ~45 Hz is indistinguishable from display rate for five slow bars and
    /// roughly halves the cost on a 120 Hz panel.
    private static let frameInterval = 1.0 / 45.0
    private static let rampDuration = 0.28
    private static let settleDuration = 0.42
    private static let restingLevel = 0.18
    /// Golden angle in radians: de-phases the bars so no two share a cycle.
    private static let goldenAngle = 2.399963229728653
    /// Mutually irrational-ish angular frequencies. Summed, they have no
    /// perceptible loop point, which is what keeps the idle animation from
    /// reading as a short repeating GIF.
    private static let omega0 = 1.93
    private static let omega1 = 3.1228
    private static let omega2 = 5.0527

    // MARK: State

    @State private var transitionStart: Double = 0
    @State private var frozen = false
    @State private var lastIsPlaying: Bool?
    @State private var positionAnchor: PositionAnchor?

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: frozen)) { context in
            let frame = frameState(at: context.date.timeIntervalSinceReferenceDate)
            Canvas(opaque: false, rendersAsynchronously: false) { graphics, size in
                WaveformView.render(frame, into: &graphics, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: isPlaying) {
            if let last = lastIsPlaying, last != isPlaying {
                transitionStart = Date.timeIntervalSinceReferenceDate
            }
            lastIsPlaying = isPlaying

            if isPlaying {
                frozen = false
            } else {
                // Let the bars fall to rest, then stop the timeline entirely.
                try? await Task.sleep(for: .milliseconds(560))
                if !Task.isCancelled {
                    frozen = true
                }
            }
        }
        .onChange(of: playbackPosition, initial: true) { _, newValue in
            positionAnchor = newValue.map {
                PositionAnchor(position: $0, clock: Date.timeIntervalSinceReferenceDate)
            }
        }
    }

    // MARK: - Per-frame resolution

    private func frameState(at time: Double) -> WaveformFrame {
        let elapsed = max(0, time - transitionStart)
        let envelope = isPlaying
            ? min(1, elapsed / Self.rampDuration)
            : max(0, 1 - elapsed / Self.settleDuration)

        return WaveformFrame(time: time,
                             envelope: envelope,
                             barCount: barCount,
                             gradient: palette.gradient,
                             beatPhase: tempo.map { beatPhase(for: $0, at: time) })
    }

    /// Position within the current beat, 0 at the downbeat. Prefers the beat
    /// grid when one is supplied, otherwise free-runs at the stated BPM.
    private func beatPhase(for tempo: TempoInfo, at time: Double) -> Double {
        let bpm = min(220, max(40, tempo.bpm))
        let interval = 60 / bpm
        let position = positionAnchor.map { $0.position + (time - $0.clock) }

        if let beats = tempo.beatTimes, beats.count >= 2, let position {
            let last = beats.count - 1
            if position <= beats[0] { return 0 }
            if position >= beats[last] {
                let phase = (position - beats[last]) / interval
                return phase - phase.rounded(.down)
            }

            var low = 0
            var high = last
            while low + 1 < high {
                let mid = (low + high) / 2
                if beats[mid] <= position { low = mid } else { high = mid }
            }

            let span = beats[high] - beats[low]
            guard span > 0.001 else { return 0 }
            return min(1, max(0, (position - beats[low]) / span))
        }

        let phase = (position ?? time) / interval
        return phase - phase.rounded(.down)
    }

    // MARK: - Drawing

    /// One `Path` and one gradient fill per frame; nothing is allocated per
    /// bar, and there are no shadows or blurs, which would force an offscreen
    /// pass. This view redraws continuously on top of whatever else the user is
    /// doing, so the draw body has to stay close to free.
    private static func render(_ frame: WaveformFrame,
                               into graphics: inout GraphicsContext,
                               size: CGSize) {
        guard size.width > 0, size.height > 0, frame.barCount > 0 else { return }

        let slot = size.width / Double(frame.barCount)
        let barWidth = max(1, slot * 0.56)
        let radius = barWidth / 2
        let maxHeight = max(barWidth, size.height)
        let minHeight = min(barWidth, maxHeight)

        var path = Path()
        for index in 0..<frame.barCount {
            let level = barLevel(index, frame)
            let height = minHeight + (maxHeight - minHeight) * level
            let x = slot * Double(index) + (slot - barWidth) / 2
            let y = (size.height - height) / 2
            path.addRoundedRect(in: CGRect(x: x, y: y, width: barWidth, height: height),
                                cornerSize: CGSize(width: radius, height: radius))
        }

        graphics.fill(path, with: .linearGradient(frame.gradient,
                                                  startPoint: .zero,
                                                  endPoint: CGPoint(x: size.width, y: size.height)))
    }

    private static func barLevel(_ index: Int, _ frame: WaveformFrame) -> Double {
        let phase = Double(index) * goldenAngle
        // A low, symmetric hill so the paused state still reads as a waveform
        // rather than a row of identical dashes.
        let rest = restingLevel
            + 0.10 * sin(.pi * (Double(index) + 0.5) / Double(frame.barCount))

        let active: Double
        if let beat = frame.beatPhase {
            var local = beat - Double(index) * 0.055
            local -= local.rounded(.down)

            let decay = 1 - local
            let attack = decay * decay * decay        // sharp onset, cubic fall
            let symmetry = 1 - abs(2 * local - 1)
            let swell = symmetry * symmetry * symmetry * symmetry
            let drift = 0.10 * sin(frame.time * 0.8 + phase)
            active = 0.24 + 0.52 * attack + 0.18 * swell + drift
        } else {
            let wave =
                0.55 * sin(frame.time * omega0 + phase) +
                0.30 * sin(frame.time * omega1 + phase * 1.7 + 0.9) +
                0.15 * sin(frame.time * omega2 + phase * 2.3 + 2.1)
            active = 0.5 + 0.5 * wave
        }

        let target = rest + (1 - rest) * min(1, max(0, active))
        return rest + (target - rest) * frame.envelope
    }
}

// MARK: - Previews

private extension AlbumPalette {
    /// A bright cover: warm orange/amber, already legible untouched.
    static let previewBright = AlbumPalette(
        primary: RGBColor(red: 0.98, green: 0.71, blue: 0.24),
        secondary: RGBColor(red: 0.90, green: 0.35, blue: 0.19),
        tertiary: RGBColor(red: 1.00, green: 0.90, blue: 0.56)
    )

    /// A near-black cover as AlbumColorExtractor hands it back: lifted off the
    /// notch's black so the bars stay visible.
    static let previewDark = AlbumPalette(
        primary: RGBColor(red: 0.42, green: 0.48, blue: 0.78),
        secondary: RGBColor(red: 0.21, green: 0.25, blue: 0.44),
        tertiary: RGBColor(red: 0.66, green: 0.72, blue: 0.95)
    )
}

#Preview("Waveform — bright artwork") {
    VStack(spacing: 22) {
        WaveformView(palette: .previewBright, isPlaying: true)
            .frame(width: 40, height: 16)
        WaveformView(palette: .previewBright, isPlaying: true, barCount: 7)
            .frame(width: 120, height: 34)
        WaveformView(palette: .previewBright, isPlaying: false)
            .frame(width: 40, height: 16)
    }
    .padding(28)
    .background(Color.black)
}

#Preview("Waveform — dark artwork") {
    VStack(spacing: 22) {
        WaveformView(palette: .previewDark, isPlaying: true)
            .frame(width: 40, height: 16)
        WaveformView(palette: .previewDark,
                     isPlaying: true,
                     tempo: TempoInfo(bpm: 128),
                     playbackPosition: 0,
                     barCount: 6)
            .frame(width: 120, height: 34)
        WaveformView(palette: .previewDark, isPlaying: false)
            .frame(width: 40, height: 16)
    }
    .padding(28)
    .background(Color.black)
}
