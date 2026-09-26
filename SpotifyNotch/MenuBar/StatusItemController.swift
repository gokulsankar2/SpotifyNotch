//
//  StatusItemController.swift
//  SpotifyNotch
//
//  The menu bar item. With LSUIElement there is no Dock icon and no window,
//  so this is the app's only conventional surface: connect/disconnect,
//  launch-at-login, settings, quit.
//

import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    /// Everything the menu needs to render itself, pushed in by the app
    /// delegate whenever it changes.
    struct Model {
        var connectionState: ConnectionState = .signedOut
        var nowPlaying: String?
        var accountTier: AccountTier = .unknown
        var launchAtLogin: Bool = false
        var hasUsableClientID: Bool = true
        var lastError: String?
    }

    var model = Model()

    // MARK: Callbacks

    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onToggleLaunchAtLogin: ((Bool) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var statusItem: NSStatusItem?

    // MARK: - Lifecycle

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "SpotifyNotch"
        )
        // Template rendering so it adapts to light/dark menu bars.
        item.button?.image?.isTemplate = true

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func remove() {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - Menu construction

    /// Rebuilt on each open so it always reflects live state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(statusHeaderItem())
        if let nowPlaying = model.nowPlaying, model.connectionState.isConnected {
            let item = NSMenuItem(title: nowPlaying, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        switch model.connectionState {
        case .connected:
            menu.addItem(actionItem("Disconnect Spotify", #selector(disconnect)))
        case .authorizing:
            let item = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        case .signedOut, .failed:
            let connect = actionItem("Connect Spotify…", #selector(connect))
            // Without a Client ID there is nothing to authorise against.
            connect.isEnabled = model.hasUsableClientID
            menu.addItem(connect)
        }

        menu.addItem(.separator())

        let launch = actionItem("Launch at Login", #selector(toggleLaunchAtLogin))
        launch.state = model.launchAtLogin ? .on : .off
        menu.addItem(launch)

        menu.addItem(actionItem("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit SpotifyNotch", #selector(quit), key: "q"))
    }

    private func statusHeaderItem() -> NSMenuItem {
        let title: String
        switch model.connectionState {
        case .connected:
            if !model.hasUsableClientID {
                title = "No Spotify Client ID set"
            } else if model.accountTier == .free {
                title = "Connected — Free account (no controls)"
            } else if model.nowPlaying == nil {
                title = "Connected — nothing playing"
            } else {
                title = "Connected"
            }
        case .authorizing:
            title = "Authorising…"
        case .signedOut:
            title = model.hasUsableClientID
                ? "Not connected"
                : "Set a Spotify Client ID in Settings"
        case .failed(let message):
            title = "Error: \(message)"
        }

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func connect() { onConnect?() }
    @objc private func disconnect() { onDisconnect?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func quit() { onQuit?() }

    @objc private func toggleLaunchAtLogin() {
        onToggleLaunchAtLogin?(!model.launchAtLogin)
    }
}
