//
//  AppSettings.swift
//  SpotifyNotch
//
//  User-visible preferences, backed by UserDefaults.
//

import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - Spotify client ID

    /// The Client ID shipped with the app, so a downloaded build works after
    /// nothing more than signing in.
    ///
    /// Spotify caps an app in Development Mode at 25 distinct users, so the
    /// bundled ID cannot serve an unbounded audience. `customClientID` lets
    /// anyone point the app at their own registered Spotify app instead.
    ///
    /// Whichever ID is used must have all of `SpotifyAuthConfig.redirectURIs`
    /// registered on the Spotify developer dashboard.
    static let bundledClientID = "7874237f7abc4a588d8b488535d904b7"

    private enum Key {
        static let customClientID = "customClientID"
        static let hasCompletedFirstConnect = "hasCompletedFirstConnect"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.customClientID = defaults.string(forKey: Key.customClientID) ?? ""
        self.hasCompletedFirstConnect = defaults.bool(forKey: Key.hasCompletedFirstConnect)
    }

    /// Overrides `bundledClientID` when non-empty.
    @Published var customClientID: String {
        didSet {
            let trimmed = customClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed, forKey: Key.customClientID)
        }
    }

    /// Whether the app has ever successfully connected. Gates the one-time
    /// automatic login-item registration.
    @Published var hasCompletedFirstConnect: Bool {
        didSet { defaults.set(hasCompletedFirstConnect, forKey: Key.hasCompletedFirstConnect) }
    }

    /// The Client ID the auth manager should actually use.
    var effectiveClientID: String {
        let trimmed = customClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.bundledClientID : trimmed
    }

    /// False when neither a bundled nor a custom ID is available, which means
    /// OAuth cannot even be attempted and the UI must say so.
    var hasUsableClientID: Bool {
        !effectiveClientID.isEmpty
    }
}
