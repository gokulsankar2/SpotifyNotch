//
//  SpotifyFocusMonitor.swift
//  SpotifyNotch
//
//  Tracks whether Spotify's own window is frontmost. When it is, the overlay
//  suppresses itself — the user is already looking at the full player, and
//  duplicating the now-playing bar on top of it is noise.
//

import AppKit
import Combine

@MainActor
final class SpotifyFocusMonitor: ObservableObject {

    static let spotifyBundleID = "com.spotify.client"

    @Published private(set) var isSpotifyFrontmost = false

    private var observers: [any NSObjectProtocol] = []

    // MARK: - Lifecycle

    func start() {
        guard observers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter

        let activated = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Only a `String` crosses into the main actor: `Notification`
            // itself is not `Sendable`, and the block already runs on main
            // because the queue is `.main`.
            let bundleID = Self.bundleIdentifier(from: notification)
            MainActor.assumeIsolated {
                self?.update(isSpotify: bundleID == Self.spotifyBundleID)
            }
        }

        // If Spotify quits while frontmost, another app takes over and we
        // would normally hear about it — but observing termination directly
        // avoids a window where the overlay stays suppressed against a
        // process that no longer exists.
        let terminated = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleID = Self.bundleIdentifier(from: notification)
            MainActor.assumeIsolated {
                guard bundleID == Self.spotifyBundleID else { return }
                self?.update(isSpotify: false)
            }
        }

        observers = [activated, terminated]
        syncWithCurrentFrontmostApp()
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        isSpotifyFrontmost = false
    }

    // MARK: - Handling

    /// Establishes the correct state at launch, rather than waiting for the
    /// next app switch — the app may well start up while Spotify is focused.
    private func syncWithCurrentFrontmostApp() {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        update(isSpotify: bundleID == Self.spotifyBundleID)
    }

    private nonisolated static func bundleIdentifier(from notification: Notification) -> String? {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        return app?.bundleIdentifier
    }

    private func update(isSpotify: Bool) {
        guard isSpotifyFrontmost != isSpotify else { return }
        isSpotifyFrontmost = isSpotify
    }
}
