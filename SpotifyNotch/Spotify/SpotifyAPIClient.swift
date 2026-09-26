//
//  SpotifyAPIClient.swift
//  SpotifyNotch
//
//  Thin async wrapper over the Spotify Web API player endpoints.
//
//  The whole point of this layer is status-code translation: the UI needs to
//  tell "free account", "no device anywhere" and "token died" apart, and each
//  arrives as a bare 4xx. `baseURL` and `session` are injectable so the
//  request/response behaviour can be exercised with a stubbed `URLProtocol`.
//

import Foundation

struct SpotifyAPIClient: Sendable {
    static let defaultBaseURL = URL(string: "https://api.spotify.com/v1")

    /// "Previous" restarts the current track once you are further than this
    /// into it, matching every other player's behaviour.
    static let restartThreshold: TimeInterval = 3

    private let tokenProvider: any AccessTokenProviding
    private let session: URLSession
    private let baseURL: URL?

    init(tokenProvider: any AccessTokenProviding,
         session: URLSession = .shared,
         baseURL: URL? = SpotifyAPIClient.defaultBaseURL) {
        self.tokenProvider = tokenProvider
        self.session = session
        self.baseURL = baseURL
    }

    // MARK: - Reads

    /// `/me/player`, which unlike `/me/player/currently-playing` also carries
    /// the active device. 204 (nothing playing anywhere) is an idle snapshot,
    /// not an error.
    func currentPlayback() async throws -> PlaybackSnapshot {
        let request = try makeRequest(path: "/me/player",
                                      method: "GET",
                                      query: [URLQueryItem(name: "additional_types", value: "track,episode")])
        let (data, response) = try await send(request)
        guard response.statusCode != 204, !data.isEmpty else { return .idle }
        let dto: SpotifyPlaybackDTO = try decode(data)
        return dto.toSnapshot()
    }

    /// `/me/player/currently-playing`. Narrower payload (no device) but it is
    /// the cheaper poll when device state is already known.
    func currentlyPlaying() async throws -> PlaybackSnapshot {
        let request = try makeRequest(path: "/me/player/currently-playing",
                                      method: "GET",
                                      query: [URLQueryItem(name: "additional_types", value: "track,episode")])
        let (data, response) = try await send(request)
        guard response.statusCode != 204, !data.isEmpty else { return .idle }
        let dto: SpotifyPlaybackDTO = try decode(data)
        return dto.toSnapshot()
    }

    func accountTier() async throws -> AccountTier {
        let request = try makeRequest(path: "/me", method: "GET")
        let (data, _) = try await send(request)
        guard !data.isEmpty else { return .unknown }
        let dto: SpotifyUserProfileDTO = try decode(data)
        return dto.accountTier
    }

    func availableDevices() async throws -> [SpotifyDevice] {
        let request = try makeRequest(path: "/me/player/devices", method: "GET")
        let (data, _) = try await send(request)
        guard !data.isEmpty else { return [] }
        let dto: SpotifyDevicesDTO = try decode(data)
        return (dto.devices ?? []).map { $0.toDevice() }
    }

    // MARK: - Transport

    func play() async throws {
        _ = try await send(try makeRequest(path: "/me/player/play", method: "PUT"))
    }

    func pause() async throws {
        _ = try await send(try makeRequest(path: "/me/player/pause", method: "PUT"))
    }

    func next() async throws {
        _ = try await send(try makeRequest(path: "/me/player/next", method: "POST"))
    }

    /// Product semantics: restart if we are more than `restartThreshold` into
    /// the track, otherwise skip back. Costs one extra read to learn the
    /// current progress — prefer `previousOrRestart(progress:)` when the
    /// caller already has a fresh snapshot.
    func previous() async throws {
        let snapshot = try await currentPlayback()
        try await previousOrRestart(progress: snapshot.progress)
    }

    func previousOrRestart(progress: TimeInterval) async throws {
        if progress > Self.restartThreshold {
            try await seek(to: 0)
        } else {
            try await skipToPrevious()
        }
    }

    /// The raw `/me/player/previous` endpoint, with no restart heuristic.
    func skipToPrevious() async throws {
        _ = try await send(try makeRequest(path: "/me/player/previous", method: "POST"))
    }

    func seek(to position: TimeInterval) async throws {
        let ms = Int(max(0, position) * 1000)
        let request = try makeRequest(path: "/me/player/seek",
                                      method: "PUT",
                                      query: [URLQueryItem(name: "position_ms", value: String(ms))])
        _ = try await send(request)
    }

    // MARK: - Request plumbing

    private func makeRequest(path: String, method: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard let baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                             resolvingAgainstBaseURL: false) else {
            throw SpotifyError.transport("Invalid Spotify API URL for \(path)")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw SpotifyError.transport("Invalid Spotify API URL for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if method == "PUT" || method == "POST" {
            // Spotify rejects a bodyless PUT/POST from some clients unless the
            // content type is declared.
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send(_ request: URLRequest, allowingRefresh: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let token: String
        do {
            token = try await tokenProvider.validAccessToken()
        } catch let error as SpotifyError {
            throw error
        } catch {
            throw SpotifyError.notAuthenticated
        }

        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: authorized)
        } catch let error as URLError {
            throw SpotifyError.transport(error.localizedDescription)
        } catch {
            throw SpotifyError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SpotifyError.transport("Non-HTTP response from the Spotify API")
        }

        switch http.statusCode {
        case 200...299:
            return (data, http)

        case 401:
            guard allowingRefresh else { throw SpotifyError.notAuthenticated }
            do {
                _ = try await tokenProvider.forceRefresh()
            } catch {
                throw SpotifyError.notAuthenticated
            }
            return try await send(request, allowingRefresh: false)

        case 403:
            // Transport control on a non-premium account.
            throw SpotifyError.premiumRequired

        case 404:
            // Player endpoints return 404 NO_ACTIVE_DEVICE rather than an
            // empty body when nothing is connected.
            throw SpotifyError.noActiveDevice

        case 429:
            throw SpotifyError.rateLimited(retryAfter: Self.retryAfter(from: http))

        default:
            throw SpotifyError.http(status: http.statusCode, message: Self.errorMessage(from: data))
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try SpotifyWire.makeDecoder().decode(T.self, from: data)
        } catch {
            throw SpotifyError.decoding(error.localizedDescription)
        }
    }

    // MARK: - Header / body parsing

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) else { return 1 }
        return max(1, seconds)
    }

    static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let envelope = try? SpotifyWire.makeDecoder().decode(SpotifyErrorEnvelopeDTO.self, from: data),
              let message = envelope.error?.message,
              !message.isEmpty else { return nil }
        return message
    }
}
