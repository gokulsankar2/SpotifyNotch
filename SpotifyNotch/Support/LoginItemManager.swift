//
//  LoginItemManager.swift
//  SpotifyNotch
//
//  Launch-at-login registration via SMAppService, so the notch is simply
//  always there after the one-time Spotify sign-in.
//

import Combine
import Foundation
import OSLog
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {

    private let logger = Logger(subsystem: "com.Majestic-Banana.SpotifyNotch", category: "LoginItem")

    @Published private(set) var isEnabled: Bool = false

    init() {
        refresh()
    }

    /// Mirrors the real system state, which the user can change behind our
    /// back in System Settings > General > Login Items.
    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // `.requiresApproval` means the registration landed but the
                // user has to allow it in System Settings; that is still a
                // success from our side.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
            return true
        } catch {
            logger.error("Login item \(enabled ? "registration" : "removal") failed: \(error.localizedDescription)")
            refresh()
            return false
        }
    }

    /// Turns launch-at-login on once, the first time Spotify connects, and
    /// never fights the user about it afterwards — if they switch it off, it
    /// stays off.
    func enableOnFirstConnectIfNeeded(settings: AppSettings) {
        guard !settings.hasCompletedFirstConnect else { return }
        settings.hasCompletedFirstConnect = true
        setEnabled(true)
    }
}
