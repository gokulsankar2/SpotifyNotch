//
//  PaletteColor.swift
//  SpotifyNotch
//
//  The only bridge between the `Sendable` RGBColor / AlbumPalette value types
//  and the platform colour types. Keeping every conversion here means the
//  extraction actor never has to touch a non-Sendable SwiftUI/AppKit colour,
//  and the rest of the app never re-derives a ramp by hand.
//

import AppKit
import SwiftUI

// MARK: - Scalar conversion

extension Color {
    init(_ rgb: RGBColor, opacity: Double = 1) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue, opacity: opacity)
    }
}

extension NSColor {
    convenience init(_ rgb: RGBColor, alpha: CGFloat = 1) {
        self.init(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: alpha)
    }
}

extension RGBColor {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

// MARK: - Palette ramps

extension AlbumPalette {
    /// Highlight -> dominant -> shadow. This is the order the waveform and the
    /// expanded card both ramp across, so tinted elements stay consistent.
    var gradient: Gradient {
        Gradient(colors: [Color(tertiary), Color(primary), Color(secondary)])
    }

    var accentColor: Color { Color(primary) }

    func linearGradient(from start: UnitPoint = .leading,
                        to end: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(gradient: gradient, startPoint: start, endPoint: end)
    }

    /// Dimmed wash for the expanded card, kept well under the notch's black so
    /// text stays readable on top of it.
    var backgroundGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                Color(primary.adjustingBrightness(by: 0.40), opacity: 0.55),
                Color(secondary.adjustingBrightness(by: 0.22), opacity: 0.18)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
