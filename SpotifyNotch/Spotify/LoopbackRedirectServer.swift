//
//  LoopbackRedirectServer.swift
//  SpotifyNotch
//
//  One-shot loopback HTTP listener that catches the Spotify OAuth redirect.
//
//  Spotify matches the `redirect_uri` against the exact string registered in
//  the developer dashboard, so the port cannot be ephemeral: we try a short
//  fixed list and use whichever binds. Register every candidate URI in the
//  dashboard (http://127.0.0.1:8888/callback, :8889, :8890).
//

import Foundation
import Network

// MARK: - One-shot continuation box

/// `NWListener`/`NWConnection` callbacks can fire more than once; this makes
/// resuming a continuation exactly once safe from any of them.
private final class OneShotContinuation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = continuation
    }

    /// Errors are concretely typed so the `Result` stays `Sendable` and can
    /// cross into the continuation without a region-isolation violation.
    func resume(with result: Result<T, LoopbackRedirectServer.Failure>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

// MARK: - Connection mailbox

/// `NWListener` rejects `start()` with EINVAL unless `newConnectionHandler` is
/// already installed, but the handler needs the actor that only exists once the
/// listener is ready. The mailbox breaks that cycle: it takes deliveries from
/// the moment the listener starts and replays them once the actor attaches.
private final class ConnectionMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [NWConnection] = []
    private var handler: (@Sendable (NWConnection) -> Void)?

    func deliver(_ connection: NWConnection) {
        lock.lock()
        let installed = handler
        if installed == nil { pending.append(connection) }
        lock.unlock()
        installed?(connection)
    }

    func attach(_ handler: @escaping @Sendable (NWConnection) -> Void) {
        lock.lock()
        self.handler = handler
        let queued = pending
        pending = []
        lock.unlock()
        for connection in queued { handler(connection) }
    }

    func drain() {
        lock.lock()
        let queued = pending
        pending = []
        handler = nil
        lock.unlock()
        for connection in queued { connection.cancel() }
    }
}

// MARK: - Server

actor LoopbackRedirectServer {
    typealias Callback = (code: String, state: String)

    /// Must stay in sync with the redirect URIs registered with Spotify.
    static let candidatePorts: [UInt16] = [8888, 8889, 8890]
    static let callbackPath = "/callback"
    static let defaultTimeout: TimeInterval = 180

    /// Every redirect URI the user must register on the Spotify dashboard.
    /// Spotify matches the redirect URI exactly, port included, so the port
    /// cannot be ephemeral — the app binds the first of these that is free.
    static var registrableRedirectURIs: [String] {
        candidatePorts.map { "http://127.0.0.1:\($0)\(callbackPath)" }
    }

    enum Failure: Error, Equatable {
        case noAvailablePort
        case listenerFailed(String)
        case timedOut
        case cancelled
        /// Spotify redirected with `?error=` — usually the user hit Cancel.
        case authorizationDenied(String)
        case malformedCallback

        var message: String {
            switch self {
            case .noAvailablePort: "No loopback port available for the Spotify redirect"
            case .listenerFailed(let detail): "Loopback listener failed: \(detail)"
            case .timedOut: "Timed out waiting for the Spotify redirect"
            case .cancelled: "Spotify sign-in was cancelled"
            case .authorizationDenied(let reason): "Spotify denied authorization: \(reason)"
            case .malformedCallback: "Spotify redirect was missing a code or state"
            }
        }
    }

    private static let networkQueue = DispatchQueue(label: "com.Majestic-Banana.SpotifyNotch.loopback")
    private static let maximumRequestBytes = 32 * 1024

    /// The exact string to send as `redirect_uri`, and to register with Spotify.
    nonisolated let redirectURI: String
    nonisolated let port: UInt16

    private let listener: NWListener
    private let mailbox: ConnectionMailbox
    private var connections: [NWConnection] = []
    private var waiter: CheckedContinuation<Callback, any Error>?
    private var outcome: Result<Callback, Failure>?
    private var timeoutTask: Task<Void, Never>?

    private init(listener: NWListener, mailbox: ConnectionMailbox, port: UInt16) {
        self.listener = listener
        self.mailbox = mailbox
        self.port = port
        self.redirectURI = "http://127.0.0.1:\(port)\(LoopbackRedirectServer.callbackPath)"
    }

    // MARK: Lifecycle

    /// Binds the first port in `ports` that accepts a listener.
    static func bind(ports: [UInt16] = LoopbackRedirectServer.candidatePorts) async throws -> LoopbackRedirectServer {
        for port in ports {
            let mailbox = ConnectionMailbox()
            guard let listener = try? await makeReadyListener(port: port, mailbox: mailbox) else { continue }
            let server = LoopbackRedirectServer(listener: listener, mailbox: mailbox, port: port)
            await server.activate()
            return server
        }
        throw Failure.noAvailablePort
    }

    private static func makeReadyListener(port: UInt16, mailbox: ConnectionMailbox) async throws -> NWListener {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw Failure.listenerFailed("invalid port \(port)")
        }

        let parameters = NWParameters.tcp
        // Stay off every other interface: the redirect only ever arrives from
        // the browser on this machine, and the App Sandbox network-server
        // entitlement should not be spent on the LAN.
        parameters.requiredInterfaceType = .loopback

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw Failure.listenerFailed(String(describing: error))
        }

        // Must be installed before `start()`; the listener fails with EINVAL
        // otherwise.
        listener.newConnectionHandler = { connection in mailbox.deliver(connection) }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let box = OneShotContinuation(continuation)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        box.resume(with: .success(()))
                    case .failed(let error):
                        box.resume(with: .failure(Failure.listenerFailed(String(describing: error))))
                    case .waiting(let error):
                        // A busy port parks in `.waiting` and retries forever,
                        // so treat it as a bind failure and move to the next.
                        box.resume(with: .failure(Failure.listenerFailed(String(describing: error))))
                    case .cancelled:
                        box.resume(with: .failure(Failure.cancelled))
                    default:
                        break
                    }
                }
                listener.start(queue: networkQueue)
            }
        } catch {
            listener.newConnectionHandler = nil
            listener.stateUpdateHandler = nil
            listener.cancel()
            mailbox.drain()
            throw error
        }

        return listener
    }

    private func activate() {
        listener.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            let detail = String(describing: error)
            Task { await self?.finish(.failure(Failure.listenerFailed(detail))) }
        }
        mailbox.attach { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }
    }

    /// Tears the listener down early; safe to call more than once.
    func stop() {
        finish(.failure(Failure.cancelled))
    }

    // MARK: Waiting

    func waitForCallback(timeout: TimeInterval = LoopbackRedirectServer.defaultTimeout) async throws -> Callback {
        if let outcome { return try outcome.get() }

        scheduleTimeout(timeout)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Callback, any Error>) in
                if let outcome {
                    continuation.resume(with: outcome)
                } else {
                    // Only one caller can own the callback; retire any earlier
                    // waiter rather than leaking its continuation.
                    waiter?.resume(with: .failure(Failure.cancelled))
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.finish(.failure(Failure.cancelled)) }
        }
    }

    private func scheduleTimeout(_ seconds: TimeInterval) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, seconds) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.finish(.failure(Failure.timedOut))
        }
    }

    private func finish(_ result: Result<Callback, Failure>) {
        guard outcome == nil else { return }
        outcome = result

        timeoutTask?.cancel()
        timeoutTask = nil

        let pending = waiter
        waiter = nil
        pending?.resume(with: result)

        // Give the browser a beat to receive the response body before the
        // socket goes away, then tear everything down.
        let sockets = connections
        connections = []
        mailbox.drain()
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        Self.networkQueue.asyncAfter(deadline: .now() + 0.25) {
            for socket in sockets { socket.cancel() }
        }
    }

    // MARK: Connection handling

    private func accept(_ connection: NWConnection) {
        guard outcome == nil else {
            connection.cancel()
            return
        }
        connections.append(connection)
        connection.start(queue: Self.networkQueue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var next = buffer
            if let chunk { next.append(chunk) }
            let failed = error != nil
            Task { await self.ingest(buffer: next, connection: connection, done: isComplete || failed) }
        }
    }

    private func ingest(buffer: Data, connection: NWConnection, done: Bool) {
        guard outcome == nil else {
            connection.cancel()
            return
        }

        guard let headerEnd = Self.headerTerminatorRange(in: buffer) else {
            if done || buffer.count > Self.maximumRequestBytes {
                connection.cancel()
            } else {
                receive(on: connection, buffer: buffer)
            }
            return
        }

        let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        guard let target = Self.requestTarget(fromHead: head) else {
            respond(on: connection, status: "400 Bad Request", html: Self.noticePage(title: "Bad request"))
            return
        }

        guard let components = URLComponents(string: "http://127.0.0.1:\(port)\(target)") else {
            respond(on: connection, status: "400 Bad Request", html: Self.noticePage(title: "Bad request"))
            return
        }

        // Browsers routinely ask for /favicon.ico alongside the redirect;
        // answer and keep waiting rather than treating it as the callback.
        guard components.path == Self.callbackPath else {
            respond(on: connection, status: "404 Not Found", html: Self.noticePage(title: "Not found"))
            return
        }

        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        if let error = query["error"] {
            respond(on: connection,
                    status: "200 OK",
                    html: Self.noticePage(title: "Sign-in cancelled",
                                          body: "SpotifyNotch was not granted access. You can close this tab."))
            finish(.failure(Failure.authorizationDenied(error)))
            return
        }

        guard let code = query["code"], let state = query["state"] else {
            respond(on: connection,
                    status: "400 Bad Request",
                    html: Self.noticePage(title: "Something went wrong",
                                          body: "The Spotify redirect was incomplete. Try signing in again."))
            finish(.failure(Failure.malformedCallback))
            return
        }

        respond(on: connection, status: "200 OK", html: Self.successPage())
        finish(.success((code: code, state: state)))
    }

    private func respond(on connection: NWConnection, status: String, html: String) {
        let body = Data(html.utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in })
    }

    // MARK: Parsing

    private static func headerTerminatorRange(in buffer: Data) -> Range<Data.Index>? {
        buffer.range(of: Data("\r\n\r\n".utf8)) ?? buffer.range(of: Data("\n\n".utf8))
    }

    /// Pulls the request target out of a `GET /callback?... HTTP/1.1` line.
    private static func requestTarget(fromHead head: String) -> String? {
        guard let line = head.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    // MARK: Pages

    private static func page(title: String, headline: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
          :root { color-scheme: dark light; }
          body {
            margin: 0; min-height: 100vh; display: grid; place-items: center;
            background: #121212; color: #f5f5f5;
            font: 400 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
          }
          .card {
            max-width: 26rem; padding: 2.5rem; text-align: center;
            background: #1c1c1c; border-radius: 18px;
            box-shadow: 0 20px 60px rgba(0,0,0,.45);
          }
          .dot { width: 14px; height: 14px; border-radius: 50%; background: #1db954; margin: 0 auto 1.25rem; }
          h1 { margin: 0 0 .5rem; font-size: 1.35rem; font-weight: 600; letter-spacing: -0.01em; }
          p { margin: 0; color: #b3b3b3; font-size: .95rem; }
        </style>
        </head>
        <body>
          <main class="card">
            <div class="dot"></div>
            <h1>\(headline)</h1>
            <p>\(body)</p>
          </main>
        </body>
        </html>
        """
    }

    private static func successPage() -> String {
        page(title: "SpotifyNotch connected",
             headline: "Connected to Spotify",
             body: "You can close this tab and return to SpotifyNotch.")
    }

    private static func noticePage(title: String, body: String = "You can close this tab.") -> String {
        page(title: title, headline: title, body: body)
    }
}
