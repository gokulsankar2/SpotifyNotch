//
//  NotchWindowController.swift
//  SpotifyNotch
//
//  Owns the overlay panel: positions it over the hardware notch, tracks hover
//  to drive the mini <-> expanded transition, and resolves the three inputs
//  (content present, Spotify frontmost, cursor inside) into a presentation.
//

import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class NotchWindowController: ObservableObject {

    // MARK: Published state

    @Published private(set) var presentation: NotchPresentation = .hidden
    @Published private(set) var geometry: NotchGeometry?

    // MARK: Inputs

    /// A track is loaded (playing or paused).
    private var hasContent = false
    /// Spotify's own window is frontmost, so the overlay would be redundant.
    private var isSuppressed = false
    private var isHovering = false

    // MARK: Internals

    private let logger = Logger(subsystem: "com.Majestic-Banana.SpotifyNotch", category: "Notch")
    private var panel: NotchPanel?
    private var hostingView: NSView?
    private var hoverTimer: Timer?
    private var hideTask: Task<Void, Never>?
    private var screenObserver: (any NSObjectProtocol)?

    /// Polling rate for cursor tracking. A global `NSEvent` monitor would be
    /// the obvious choice, but mouse-moved monitors are unreliable under the
    /// App Sandbox; reading `NSEvent.mouseLocation` needs no entitlement and
    /// no accessibility permission. At 30 Hz the cost is negligible, and the
    /// timer only runs while the overlay is actually on screen.
    private static let hoverPollInterval: TimeInterval = 1.0 / 30.0

    // MARK: - Lifecycle

    /// Installs the overlay. `rootView` is retained as the panel's content.
    func install(rootView: some View) {
        refreshGeometry()

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = true
        // Empty sizing options: the panel's frame is computed from the notch
        // geometry and must not be renegotiated from SwiftUI's intrinsic
        // content size, which would shrink the window around the content.
        hosting.sizingOptions = []
        hostingView = hosting

        // Nothing to attach to on a Mac without a notch; scope is real
        // hardware notches only, so the app simply stays dormant.
        guard let geometry else { return }

        let panel = NotchPanel(contentRect: geometry.panelFrame)
        panel.contentView = hosting
        // Reassert the frame after the content view is attached, since
        // installing it can otherwise renegotiate the window's size.
        panel.setFrame(geometry.panelFrame, display: false)
        self.panel = panel

        logger.notice("""
            Notch detected: notch=\(geometry.notchRect.debugDescription, privacy: .public) \
            panel=\(panel.frame.debugDescription, privacy: .public) \
            requested=\(geometry.panelFrame.debugDescription, privacy: .public) \
            hosting=\(hosting.frame.debugDescription, privacy: .public)
            """)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenChange()
            }
        }

        applyPresentation()
    }

    // MARK: - Input updates

    func setHasContent(_ value: Bool) {
        guard hasContent != value else { return }
        hasContent = value
        applyPresentation()
    }

    func setSuppressed(_ value: Bool) {
        guard isSuppressed != value else { return }
        isSuppressed = value
        // Never leave the card hanging open after the overlay is hidden.
        if value { isHovering = false }
        applyPresentation()
    }

    // MARK: - Geometry

    private func refreshGeometry() {
        let detected = NotchGeometry.detect()
        if detected != geometry { geometry = detected }
    }

    /// Re-resolves the notched screen after a display is attached, detached,
    /// or rescaled. The built-in panel can change origin when an external
    /// monitor's arrangement changes, so the frame is always reapplied.
    private func handleScreenChange() {
        refreshGeometry()
        guard let geometry, let panel else {
            // Notched display went away (clamshell, display asleep).
            panel?.orderOut(nil)
            return
        }
        panel.setFrame(geometry.panelFrame, display: true)
        applyPresentation()
    }

    // MARK: - Presentation resolution

    private func resolvedPresentation() -> NotchPresentation {
        guard geometry != nil, hasContent, !isSuppressed else { return .hidden }
        return isHovering ? .expanded : .mini
    }

    private func applyPresentation() {
        let next = resolvedPresentation()
        let changed = next != presentation

        if changed {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                presentation = next
            }
        }

        switch next {
        case .hidden:
            stopHoverTracking()
            scheduleHide()
        case .mini, .expanded:
            hideTask?.cancel()
            hideTask = nil
            if let panel, !panel.isVisible {
                panel.orderFrontRegardless()
            }
            startHoverTracking()
        }

        applyMouseTransparency(for: next)
    }

    /// Orders the panel out only after the retract animation has played, so
    /// the overlay shrinks into the notch instead of blinking out of it.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled else { return }
            guard let self, self.presentation == .hidden else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// The panel swallows clicks only while expanded, where there are actual
    /// controls to hit. In the mini state it must stay click-through so the
    /// menu bar underneath remains usable.
    private func applyMouseTransparency(for presentation: NotchPresentation) {
        panel?.ignoresMouseEvents = (presentation != .expanded)
    }

    // MARK: - Hover tracking

    private func startHoverTracking() {
        guard hoverTimer == nil else { return }
        let timer = Timer(
            timeInterval: Self.hoverPollInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollHover()
            }
        }
        // `.common` so tracking survives menu tracking and window drags.
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        isHovering = false
    }

    private func pollHover() {
        guard let geometry else { return }
        let location = NSEvent.mouseLocation
        let zone = geometry.hoverZone(for: presentation)
        let inside = zone.contains(location)

        guard inside != isHovering else { return }
        isHovering = inside
        applyPresentation()
    }
}
