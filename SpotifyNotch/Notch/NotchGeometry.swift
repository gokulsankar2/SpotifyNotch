//
//  NotchGeometry.swift
//  SpotifyNotch
//
//  Detects the built-in notched display and derives the rects the overlay
//  panel is positioned from. Uses only Apple-sanctioned public API:
//  `safeAreaInsets.top` to identify a notched screen, and the gap between
//  `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` to measure the notch.
//

import AppKit

// MARK: - Metrics

/// Layout constants for the three presentation states.
///
/// Tuned against a 14-inch M-series MacBook Pro, where the hardware notch
/// measures 185 x 32 pt. Everything is expressed relative to the measured
/// notch rather than hard-coded, so other notch sizes scale correctly.
enum NotchMetrics {
    /// Width of each lobe flanking the hardware notch in the mini state.
    /// The left lobe holds album art, the right holds the waveform.
    static let miniLobeWidth: CGFloat = 72

    /// Horizontal padding inside a lobe.
    static let lobePadding: CGFloat = 8

    /// How far the expanded card grows beyond the hardware notch.
    ///
    /// Applied equally to the left, right and bottom, so the card radiates
    /// symmetrically from the notch's two bottom corners rather than mostly
    /// hanging downward. On a 185 x 32 notch this yields 425 x 152 — close to
    /// the proportions of the iPhone Dynamic Island's expanded state.
    ///
    /// The expanded card's content must fit inside the resulting height; it
    /// is clipped to the notch silhouette, and the first thing to be cut off
    /// is the transport row along the bottom. `NotchGeometryTests` guards it.
    static let expansion: CGFloat = 120

    /// Lower-corner radius of the expanded card. Much softer than the mini
    /// state's, which is what gives it the rounded-island read.
    static let expandedBottomRadius: CGFloat = 44

    /// Radius of the overlay's lower corners, matching the hardware notch's
    /// own curvature closely enough to read as one continuous shape.
    static let bottomCornerRadius: CGFloat = 13

    /// Radius of the concave fillets where the overlay meets the screen edge.
    static let topCornerRadius: CGFloat = 8

    /// Extra slack around the collapse hit-test so the overlay does not
    /// flicker shut when the cursor grazes its boundary.
    static let hoverExitSlop: CGFloat = 6
}

// MARK: - Geometry

/// A resolved description of the notched screen and the overlay rects
/// derived from it. Recomputed whenever the screen configuration changes.
struct NotchGeometry: Equatable, Sendable {
    /// Global-coordinate frame of the screen that physically has a notch.
    let screenFrame: CGRect
    /// Global-coordinate rect of the hardware notch cutout itself.
    let notchRect: CGRect
    let backingScale: CGFloat

    var notchWidth: CGFloat { notchRect.width }
    var notchHeight: CGFloat { notchRect.height }

    // MARK: State rects

    /// Centres a rect on the notch, widening it by a single point when that
    /// is what it takes to land the origin on a whole point.
    ///
    /// The notch is an odd number of points wide, so its midpoint falls on a
    /// half-point. An even-width rect centred there would start at `x.5`, and
    /// AppKit rounds window origins to whole points — which would shift the
    /// whole overlay a pixel off the hardware notch it is supposed to be
    /// indistinguishable from.
    private func centredRect(width: CGFloat, height: CGFloat, topEdge: CGFloat) -> CGRect {
        var width = width
        if (notchRect.midX - width / 2).truncatingRemainder(dividingBy: 1) != 0 {
            width += 1
        }
        return CGRect(
            x: notchRect.midX - width / 2,
            y: topEdge - height,
            width: width,
            height: height
        )
    }

    /// `NotchShape` spans the full frame width only at the very top edge and
    /// sits inset by `topCornerRadius` on each side below the concave flare.
    /// Frames are widened by that inset so the *visible* shape is the size
    /// the metrics actually name.
    private static var flareInset: CGFloat { NotchMetrics.topCornerRadius * 2 }

    /// Notch plus both lobes, centred on the hardware notch.
    /// This doubles as the hover-entry zone.
    var miniRect: CGRect {
        centredRect(
            width: notchRect.width + NotchMetrics.miniLobeWidth * 2 + Self.flareInset,
            height: notchRect.height,
            topEdge: notchRect.maxY
        )
    }

    /// The full card. Grown from the notch by `NotchMetrics.expansion` on the
    /// left, right and bottom alike, so the distance from each bottom corner
    /// of the notch to the card's edge is the same in every direction.
    var expandedRect: CGRect {
        centredRect(
            width: max(
                notchRect.width + NotchMetrics.expansion * 2 + Self.flareInset,
                miniRect.width
            ),
            height: notchRect.height + NotchMetrics.expansion,
            topEdge: screenFrame.maxY
        )
    }

    /// The expanded card as the user actually sees it, with the flare inset
    /// removed. This is the rect that grows equally in every direction.
    var expandedVisibleRect: CGRect {
        expandedRect.insetBy(dx: NotchMetrics.topCornerRadius, dy: 0)
    }

    /// The panel is kept at a single fixed frame large enough for every state,
    /// and the SwiftUI content animates within it. Resizing an `NSWindow` on
    /// each hover transition produces visible tearing against the live
    /// desktop behind it, so the window stays still and only pixels move.
    var panelFrame: CGRect {
        centredRect(
            width: max(expandedRect.width, miniRect.width),
            height: expandedRect.height,
            topEdge: screenFrame.maxY
        )
    }

    /// `miniRect` expressed in the panel's own bottom-left-origin coordinates.
    var miniRectInPanel: CGRect {
        let panel = panelFrame
        return CGRect(
            x: miniRect.minX - panel.minX,
            y: miniRect.minY - panel.minY,
            width: miniRect.width,
            height: miniRect.height
        )
    }

    // MARK: Hit testing

    /// Whether a global-coordinate point should keep the overlay open,
    /// given which state it is currently in.
    func hoverZone(for presentation: NotchPresentation) -> CGRect {
        switch presentation {
        case .hidden, .mini:
            // Entering: only the visible mini strip counts.
            return miniRect
        case .expanded:
            // Leaving: allow slop so a cursor tracking toward a button
            // does not collapse the card out from under itself.
            return expandedRect.insetBy(
                dx: -NotchMetrics.hoverExitSlop,
                dy: -NotchMetrics.hoverExitSlop
            )
        }
    }

    // MARK: Detection

    /// Locates the built-in notched display.
    ///
    /// Deliberately does **not** use `NSScreen.main`: with an external monitor
    /// attached the main screen is usually the external one, and the notched
    /// built-in panel can sit at a negative origin. Scope is real hardware
    /// notches only, so a screen without one yields `nil`.
    @MainActor
    static func detect() -> NotchGeometry? {
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0,
                  let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea
            else { continue }

            let notchWidth = right.minX - left.maxX
            let notchHeight = screen.safeAreaInsets.top
            guard notchWidth > 0, notchHeight > 0 else { continue }

            let notchRect = CGRect(
                x: left.maxX,
                y: screen.frame.maxY - notchHeight,
                width: notchWidth,
                height: notchHeight
            )

            return NotchGeometry(
                screenFrame: screen.frame,
                notchRect: notchRect,
                backingScale: screen.backingScaleFactor
            )
        }
        return nil
    }
}
