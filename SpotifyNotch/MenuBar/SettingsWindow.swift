//
//  SettingsWindow.swift
//  SpotifyNotch
//
//  A single small preferences window. The app has no Dock icon and no main
//  window, so this is created on demand from the menu bar.
//

import AppKit
import SwiftUI

// MARK: - View

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var loginItem: LoginItemManager

    /// Kept separate from `settings.customClientID` so a half-typed ID does
    /// not get written to disk on every keystroke.
    @State private var draftClientID: String = ""
    @State private var didSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Divider()

            clientIDSection

            Divider()

            Toggle("Launch at login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)

            Spacer(minLength: 0)

            footer
        }
        .padding(22)
        .frame(width: 460, height: 420)
        .onAppear { draftClientID = settings.customClientID }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SpotifyNotch")
                .font(.title2.weight(.semibold))
            Text("A Dynamic Island for Spotify, in the notch.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var clientIDSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spotify Client ID")
                .font(.headline)

            Text(clientIDExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Leave blank to use the bundled ID", text: $draftClientID)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Text("Register these redirect URIs on your Spotify app:")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(LoopbackRedirectServer.registrableRedirectURIs, id: \.self) { uri in
                Text(uri)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Save") {
                    settings.customClientID = draftClientID
                    didSave = true
                }
                .disabled(draftClientID == settings.customClientID)

                Link(
                    "Open Spotify Dashboard",
                    destination: URL(string: "https://developer.spotify.com/dashboard")!
                )
                .font(.callout)

                if didSave {
                    Text("Saved — reconnect to apply.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var clientIDExplanation: String {
        """
        SpotifyNotch ships with a Client ID so it works out of the box. \
        Spotify caps an app in Development Mode at 25 users, so if sign-in \
        fails with an access error, register your own app and paste its \
        Client ID here.
        """
    }

    private var footer: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return HStack {
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            Link(
                "Source",
                destination: URL(string: "https://github.com/")!
            )
            .font(.caption)
        }
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController {

    private var window: NSWindow?

    func show(settings: AppSettings, loginItem: LoginItemManager) {
        loginItem.refresh()

        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: SettingsView(settings: settings, loginItem: loginItem)
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = "SpotifyNotch Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        // LSUIElement apps are not activated by default, so the window would
        // otherwise open behind whatever the user is looking at.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
