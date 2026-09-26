//
//  SpotifyAuthManager.swift
//  SpotifyNotch
//
//  Authorization Code + PKCE against accounts.spotify.com, with the redirect
//  caught by `LoopbackRedirectServer` and tokens parked in the Keychain.
//
//  Why not ASWebAuthenticationSession: it completes on a callback URL scheme
//  (or an HTTPS associated domain) and will not hand back an `http://127.0.0.1`
//  redirect, which is the only redirect form Spotify still accepts. So the
//  authorize URL is opened in the user's default browser with NSWorkspace and
//  the loopback listener receives the code.
//
//  Observing connection state: `SpotifyAuthManager` is an actor, so it
//  publishes `ConnectionState` through `connectionStates()`, a multicast
//  `AsyncStream` that replays the current value on subscribe. SwiftUI should
//  use `SpotifyConnectionObserver`, the `@MainActor ObservableObject` wrapper
//  at the bottom of this file, which drains that stream into `@Published`.
//

import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - Token provider seam

protocol AccessTokenProviding: Sendable {
    func validAccessToken() async throws -> String
    func forceRefresh() async throws -> String
}

// MARK: - Auth manager

actor SpotifyAuthManager: AccessTokenProviding {
    /// Exactly the scopes the notch needs — read now-playing, read device
    /// state, and drive transport.
    static let scopes = "user-read-currently-playing user-read-playback-state user-modify-playback-state"

    static let authorizeEndpoint = URL(string: "https://accounts.spotify.com/authorize")
    static let tokenEndpoint = URL(string: "https://accounts.spotify.com/api/token")

    /// Refresh anything expiring inside this window rather than letting a
    /// poll eat a 401.
    static let refreshLeeway: TimeInterval = 60

    private let clientID: String
    private let keychain: KeychainStore
    private let session: URLSession
    private let redirectPorts: [UInt16]

    private var cachedTokens: SpotifyTokens?
    private var didLoadFromKeychain = false
    private var refreshTask: Task<String, any Error>?
    private var authorizationTask: Task<Void, any Error>?
    private var activeServer: LoopbackRedirectServer?

    private var state: ConnectionState = .signedOut
    private var observers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    init(clientID: String,
         keychain: KeychainStore = KeychainStore(),
         session: URLSession = .shared,
         redirectPorts: [UInt16] = LoopbackRedirectServer.candidatePorts) {
        self.clientID = clientID
        self.keychain = keychain
        self.session = session
        self.redirectPorts = redirectPorts
    }

    // MARK: Connection state

    var connectionState: ConnectionState { state }

    /// Replays the current state, then every subsequent transition.
    /// Terminates when the consuming task is cancelled.
    nonisolated func connectionStates() -> AsyncStream<ConnectionState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let id = UUID()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeObserver(id) }
            }
            Task { await self.addObserver(id, continuation) }
        }
    }

    private func addObserver(_ id: UUID, _ continuation: AsyncStream<ConnectionState>.Continuation) {
        observers[id] = continuation
        continuation.yield(state)
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func setState(_ next: ConnectionState) {
        guard next != state else { return }
        state = next
        for continuation in observers.values { continuation.yield(next) }
    }

    /// Call once at launch: promotes a stored refresh token to `.connected`
    /// without any network round-trip, so the notch can start polling.
    @discardableResult
    func restoreSession() -> ConnectionState {
        let stored = (try? storedTokens()) ?? nil
        setState(stored == nil ? .signedOut : .connected)
        return state
    }

    // MARK: Sign in / out

    /// Opens the Spotify consent page in the default browser and resolves once
    /// the loopback listener receives a matching `code`/`state` pair.
    func signIn() async throws {
        if let authorizationTask {
            return try await authorizationTask.value
        }
        let task = Task { try await self.performAuthorization() }
        authorizationTask = task
        defer { authorizationTask = nil }
        try await task.value
    }

    /// Aborts an in-flight sign-in (menu-bar Cancel).
    func cancelSignIn() async {
        authorizationTask?.cancel()
        await activeServer?.stop()
        activeServer = nil
    }

    func signOut() {
        try? keychain.delete()
        cachedTokens = nil
        didLoadFromKeychain = true
        refreshTask?.cancel()
        refreshTask = nil
        authorizationTask?.cancel()
        authorizationTask = nil
        setState(.signedOut)
    }

    private func performAuthorization() async throws {
        setState(.authorizing)
        do {
            let verifier = Self.randomURLSafeString(length: 64)
            let challenge = Self.codeChallenge(for: verifier)
            let expectedState = Self.randomURLSafeString(length: 24)

            let server = try await LoopbackRedirectServer.bind(ports: redirectPorts)
            activeServer = server
            defer { activeServer = nil }

            let redirectURI = server.redirectURI
            guard let authorizeURL = authorizeURL(redirectURI: redirectURI,
                                                  challenge: challenge,
                                                  state: expectedState) else {
                throw SpotifyError.transport("Could not build the Spotify authorize URL")
            }

            let opened = await MainActor.run { NSWorkspace.shared.open(authorizeURL) }
            guard opened else {
                await server.stop()
                throw SpotifyError.transport("Could not open the Spotify sign-in page")
            }

            let callback = try await server.waitForCallback()
            guard callback.state == expectedState else {
                throw SpotifyError.transport("Spotify returned a mismatched state parameter")
            }

            let tokens = try await exchange(code: callback.code,
                                            verifier: verifier,
                                            redirectURI: redirectURI)
            try persist(tokens)
            setState(.connected)
        } catch {
            setState(.failed(Self.describe(error)))
            throw error
        }
    }

    private func authorizeURL(redirectURI: String, challenge: String, state: String) -> URL? {
        guard let endpoint = Self.authorizeEndpoint,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes)
        ]
        return components.url
    }

    // MARK: AccessTokenProviding

    func validAccessToken() async throws -> String {
        guard let tokens = try storedTokens() else { throw SpotifyError.notAuthenticated }
        guard tokens.isExpired(within: Self.refreshLeeway) else { return tokens.accessToken }
        return try await refresh(using: tokens.refreshToken)
    }

    func forceRefresh() async throws -> String {
        guard let tokens = try storedTokens() else { throw SpotifyError.notAuthenticated }
        return try await refresh(using: tokens.refreshToken)
    }

    /// Coalesces concurrent refreshes so a burst of polls produces one
    /// token request, not several (Spotify invalidates racing grants).
    private func refresh(using refreshToken: String) async throws -> String {
        if let refreshTask {
            return try await refreshTask.value
        }
        let task = Task { try await self.performRefresh(refreshToken: refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(refreshToken: String) async throws -> String {
        do {
            let body = [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": clientID
            ]
            let response = try await postToken(body)
            // Spotify only sometimes rotates the refresh token; when it is
            // absent the previous one stays valid.
            let tokens = SpotifyTokens(
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? refreshToken,
                expiresAt: Date().addingTimeInterval(response.expiresIn)
            )
            try persist(tokens)
            setState(.connected)
            return tokens.accessToken
        } catch let error as SpotifyError {
            if case .notAuthenticated = error {
                cachedTokens = nil
                try? keychain.delete()
                setState(.signedOut)
            }
            throw error
        }
    }

    private func exchange(code: String, verifier: String, redirectURI: String) async throws -> SpotifyTokens {
        let response = try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ])
        guard let refreshToken = response.refreshToken else {
            throw SpotifyError.decoding("Spotify did not return a refresh token")
        }
        return SpotifyTokens(
            accessToken: response.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(response.expiresIn)
        )
    }

    // MARK: Token endpoint

    private struct TokenResponse: Decodable {
        let accessToken: String
        let tokenType: String?
        let expiresIn: TimeInterval
        let refreshToken: String?
        let scope: String?
    }

    private struct TokenErrorResponse: Decodable {
        let error: String?
        let errorDescription: String?
    }

    private func postToken(_ fields: [String: String]) async throws -> TokenResponse {
        guard let endpoint = Self.tokenEndpoint else {
            throw SpotifyError.transport("Invalid Spotify token endpoint")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncoded(fields).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SpotifyError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.transport("Non-HTTP response from the Spotify token endpoint")
        }

        let decoder = SpotifyWire.makeDecoder()

        guard (200...299).contains(http.statusCode) else {
            let payload = try? decoder.decode(TokenErrorResponse.self, from: data)
            let detail = payload?.errorDescription ?? payload?.error
            // invalid_grant means the refresh token is gone for good.
            if http.statusCode == 400 || http.statusCode == 401 {
                throw SpotifyError.notAuthenticated
            }
            if http.statusCode == 429 {
                throw SpotifyError.rateLimited(retryAfter: Self.retryAfter(from: http))
            }
            throw SpotifyError.http(status: http.statusCode, message: detail)
        }

        do {
            return try decoder.decode(TokenResponse.self, from: data)
        } catch {
            throw SpotifyError.decoding(error.localizedDescription)
        }
    }

    // MARK: Storage

    private func storedTokens() throws -> SpotifyTokens? {
        if !didLoadFromKeychain {
            didLoadFromKeychain = true
            cachedTokens = try? keychain.load()
        }
        return cachedTokens
    }

    private func persist(_ tokens: SpotifyTokens) throws {
        cachedTokens = tokens
        didLoadFromKeychain = true
        do {
            try keychain.save(tokens)
        } catch let failure as KeychainStore.Failure {
            throw SpotifyError.transport(failure.message)
        }
    }

    // MARK: PKCE helpers

    /// Unreserved characters only, per RFC 7636 §4.1. `SystemRandomNumberGenerator`
    /// is the platform CSPRNG, and picking per character avoids modulo bias.
    static func randomURLSafeString(length: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        let clamped = min(max(length, 43), 128)
        let characters = (0..<clamped).map { _ in alphabet.randomElement(using: &generator) ?? "x" }
        return String(characters)
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else { return 1 }
        return max(1, seconds)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case let spotify as SpotifyError: spotify.message
        case let loopback as LoopbackRedirectServer.Failure: loopback.message
        case is CancellationError: "Spotify sign-in was cancelled"
        default: error.localizedDescription
        }
    }
}

// MARK: - base64url

extension Data {
    /// base64url without padding, as required for the PKCE `code_challenge`.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - SwiftUI observation

/// Drains `SpotifyAuthManager.connectionStates()` into a `@Published` value so
/// views can react without touching the actor directly.
@MainActor
final class SpotifyConnectionObserver: ObservableObject {
    @Published private(set) var state: ConnectionState = .signedOut

    private var task: Task<Void, Never>?

    init(auth: SpotifyAuthManager) {
        task = Task { [weak self] in
            for await next in auth.connectionStates() {
                guard let self else { return }
                self.state = next
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
