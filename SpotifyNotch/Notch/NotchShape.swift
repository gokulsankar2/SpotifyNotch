//
//  NotchShape.swift
//  SpotifyNotch
//
//  The silhouette shared by the mini and expanded states: square against the
//  top screen edge, concave fillets flaring out to meet it, and convex
//  rounded lower corners. This is what makes the overlay read as the hardware
//  notch growing rather than as a separate floating window.
//

import SwiftUI

struct NotchShape: Shape {
    /// Radius of the concave flares where the shape meets the screen edge.
    var topRadius: CGFloat
    /// Radius of the convex lower corners.
    var bottomRadius: CGFloat

    /// Lets the silhouette morph smoothly during the mini <-> expanded
    /// transition instead of popping between two corner radii.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        // Clamp so extreme radii on a short rect cannot invert the path.
        let top = max(0, min(topRadius, rect.width / 2))
        let bottom = max(0, min(bottomRadius, min(rect.height, rect.width / 2 - top)))

        var path = Path()

        // Top-left, flush with the screen edge, curving inward.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        // Left edge down to the lower corner.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )

        // Right edge back up, then the mirrored concave flare.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

#Preview("Mini") {
    NotchShape(topRadius: 8, bottomRadius: 13)
        .fill(.black)
        .frame(width: 329, height: 32)
        .padding(40)
        .background(Color.gray.opacity(0.3))
}

#Preview("Expanded") {
    NotchShape(topRadius: 10, bottomRadius: 26)
        .fill(.black)
        .frame(width: 380, height: 180)
        .padding(40)
        .background(Color.gray.opacity(0.3))
}
