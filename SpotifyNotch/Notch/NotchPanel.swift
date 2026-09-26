//
//  NotchPanel.swift
//  SpotifyNotch
//
//  The borderless overlay window itself.
//

import AppKit

/// A transparent, non-activating panel pinned over the hardware notch.
///
/// It deliberately never becomes key or main. If clicking the overlay
/// activated SpotifyNotch, it would pull focus away from whatever the user
/// was doing — and would also make Spotify stop being frontmost, which would
/// fight `SpotifyFocusMonitor`'s suppression logic.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Sit above the menu bar, which occupies the same strip of screen.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        isMovable = false
        isMovableByWindowBackground = false
        isRestorable = false
        hidesOnDeactivate = false

        // Follow the user across Spaces, stay put during Exposé, and never
        // show up in the window cycler.
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]

        // Mouse events are opted into only while expanded; see
        // `NotchWindowController.applyMouseTransparency`.
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    /// AppKit otherwise pushes any window down so it cannot overlap the menu
    /// bar — which is exactly the strip of screen this overlay has to occupy.
    /// Returning the rect unchanged keeps the panel flush with the top edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
