//
//  KeychainStore.swift
//  SpotifyNotch
//
//  Keychain persistence for the Spotify OAuth token blob. A value type over
//  `SecItem*` so it can be injected into the auth actor and crosses actor
//  boundaries without any shared mutable state of its own.
//

import Foundation
import Security

// MARK: - Token blob

/// The full credential set persisted between launches. Spotify's refresh
/// token is long-lived, which is what makes the app zero-touch after the
/// one-time login.
struct SpotifyTokens: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// True when the access token is already dead, or close enough that a
    /// request issued now would probably land after it expires.
    func isExpired(within leeway: TimeInterval = 0, now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) <= leeway
    }
}

// MARK: - Store

struct KeychainStore: Sendable {
    /// Bundle-scoped service string; changing it orphans existing logins.
    static let defaultService = "com.Majestic-Banana.SpotifyNotch.tokens"
    static let defaultAccount = "spotify-oauth"

    enum Failure: Error, Equatable {
        case unhandled(OSStatus)
        case malformedItem

        var message: String {
            switch self {
            case .unhandled(let status): "Keychain error \(status)"
            case .malformedItem: "Stored Spotify credentials could not be read"
            }
        }
    }

    let service: String
    let account: String

    init(service: String = KeychainStore.defaultService,
         account: String = KeychainStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    // MARK: Operations

    func save(_ tokens: SpotifyTokens) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw Failure.malformedItem
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // The app runs as a login item, so it must be able to read the
            // token before the user has unlocked the keychain interactively.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(identityQuery() as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = identityQuery()
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.unhandled(addStatus) }
        default:
            throw Failure.unhandled(updateStatus)
        }
    }

    /// Returns `nil` when nothing has ever been stored, which the auth layer
    /// treats as `SpotifyError.notAuthenticated` rather than a failure.
    func load() throws -> SpotifyTokens? {
        var query = identityQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.malformedItem }
            do {
                return try JSONDecoder().decode(SpotifyTokens.self, from: data)
            } catch {
                throw Failure.malformedItem
            }
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unhandled(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(identityQuery() as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound: return
        default: throw Failure.unhandled(status)
        }
    }

    // MARK: Helpers

    private func identityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
