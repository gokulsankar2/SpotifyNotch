//
//  AppDelegate.swift
//  SpotifyNotch
//
//  Composition root. Builds every subsystem, wires them together, and owns
//  their lifetimes. There is no Dock icon and no main window — the menu bar
//  item and the notch overlay are the entire surface of the app.
//

import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: Subsystems

    private let logger = Logger(subsystem: "com.Majestic-Banana.SpotifyNotch", category: "App")
    private let settings = AppSettings.shared
    private let loginItem = LoginItemManager()
    private let focusMonitor = SpotifyFocusMonitor()
    private let notchController = NotchWindowController()
    private let statusItem = StatusItemController()
    private let settingsWindow = SettingsWindowController()

    private var auth: SpotifyAuthManager?
    private var connection: SpotifyConnectionObserver?
    private var playback: PlaybackViewModel?

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests run against this app as their host, which would
        // otherwise spin up the overlay and start polling Spotify mid-suite.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }

        statusItem.install()
        wireStatusItemActions()

#if DEBUG
        if isDemoMode {
            startDemoMode()
            return
        }
#endif

        buildSpotifyStack()
        installOverlay()
        startFocusMonitoring()

        refreshStatusItemModel()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: - Composition

#if DEBUG
    /// `SPOTIFYNOTCH_DEMO=1` paints the overlay from canned data instead of
    /// connecting to Spotify, for verifying layout and hover behaviour.
    private var isDemoMode: Bool {
        ProcessInfo.processInfo.environment["SPOTIFYNOTCH_DEMO"] == "1"
    }

    private func startDemoMode() {
        let auth = SpotifyAuthManager(clientID: "demo")
        let playback = PlaybackViewModel(client: SpotifyAPIClient(tokenProvider: auth))
        self.playback = playback

        observePlayback(playback)
        installOverlay()
        startFocusMonitoring()
        playback.startDemo()
    }
#endif

    private func buildSpotifyStack() {
        let clientID = settings.effectiveClientID
        guard !clientID.isEmpty else {
            // Nothing to authenticate against; the menu bar explains why and
            // points at Settings.
            return
        }

        let auth = SpotifyAuthManager(clientID: clientID)
        let client = SpotifyAPIClient(tokenProvider: auth)
        let playback = PlaybackViewModel(client: client)
        let connection = SpotifyConnectionObserver(auth: auth)

        self.auth = auth
        self.playback = playback
        self.connection = connection

        observeConnection(connection, auth: auth, playback: playback)
        observePlayback(playback)

        // Promote a stored refresh token straight to connected, so a track
        // already playing shows up without any user interaction at launch.
        Task { await auth.restoreSession() }
    }

    private func installOverlay() {
        guard let playback else {
            notchController.install(rootView: EmptyView())
            return
        }

        notchController.install(
            rootView: NotchRootView(
                notch: notchController,
                playback: playback,
                artwork: playback.artwork,
                progress: playback.progress
            )
        )
    }

    // MARK: - Wiring

    private func observeConnection(
        _ connection: SpotifyConnectionObserver,
        auth: SpotifyAuthManager,
        playback: PlaybackViewModel
    ) {
        connection.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.logger.notice("Connection state -> \(String(describing: state), privacy: .public)")
                switch state {
                case .connected:
                    playback.start()
                    // Launch-at-login is switched on exactly once, the first
                    // time a connection succeeds.
                    self.loginItem.enableOnFirstConnectIfNeeded(settings: self.settings)
                case .signedOut, .failed:
                    playback.stop()
                case .authorizing:
                    break
                }
                self.refreshStatusItemModel()
            }
            .store(in: &cancellables)
    }

    private func observePlayback(_ playback: PlaybackViewModel) {
        // The overlay is shown only when there is something to show.
        playback.$snapshot
            .map(\.hasTrack)
            .removeDuplicates()
            .sink { [weak self] hasTrack in
                self?.notchController.setHasContent(hasTrack)
            }
            .store(in: &cancellables)

        playback.$snapshot
            .map { snapshot -> String? in
                guard let track = snapshot.track else { return nil }
                return "\(track.title) — \(track.artist)"
            }
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshStatusItemModel() }
            .store(in: &cancellables)

        playback.$accountTier
            .removeDuplicates()
            .sink { [weak self] _ in self?.refreshStatusItemModel() }
            .store(in: &cancellables)
    }

    private func startFocusMonitoring() {
        focusMonitor.$isSpotifyFrontmost
            .removeDuplicates()
            .sink { [weak self] frontmost in
                guard let self else { return }
                // Hide the overlay, and slow polling down while it is hidden.
                self.notchController.setSuppressed(frontmost)
                self.playback?.setSuppressed(frontmost)
            }
            .store(in: &cancellables)

        focusMonitor.start()
    }

    // MARK: - Menu bar

    private func wireStatusItemActions() {
        statusItem.onConnect = { [weak self] in self?.connectSpotify() }
        statusItem.onDisconnect = { [weak self] in self?.disconnectSpotify() }
        statusItem.onOpenSettings = { [weak self] in
            guard let self else { return }
            self.settingsWindow.show(settings: self.settings, loginItem: self.loginItem)
        }
        statusItem.onToggleLaunchAtLogin = { [weak self] enabled in
            guard let self else { return }
            self.loginItem.setEnabled(enabled)
            self.refreshStatusItemModel()
        }
        statusItem.onQuit = { NSApp.terminate(nil) }
    }

    private func connectSpotify() {
        // The client ID may have been filled in since launch.
        if auth == nil { buildSpotifyStack(); installOverlay() }
        guard let auth else { return }
        Task { try? await auth.signIn() }
    }

    private func disconnectSpotify() {
        guard let auth else { return }
        Task { await auth.signOut() }
    }

    private func refreshStatusItemModel() {
        loginItem.refresh()
        statusItem.model = StatusItemController.Model(
            connectionState: connection?.state ?? .signedOut,
            nowPlaying: playback?.snapshot.track.map { "\($0.title) — \($0.artist)" },
            accountTier: playback?.accountTier ?? .unknown,
            launchAtLogin: loginItem.isEnabled,
            hasUsableClientID: settings.hasUsableClientID,
            lastError: playback?.statusMessage
        )
    }
}
