//
//  LoopbackRedirectServerTests.swift
//  SpotifyNotchTests
//
//  End-to-end exercise of the OAuth redirect listener: bind a real loopback
//  port, drive a real HTTP request at it, and check what comes back out.
//  This is the one piece of the auth flow that can be tested without a
//  Spotify account.
//

import XCTest
@testable import SpotifyNotch

final class LoopbackRedirectServerTests: XCTestCase {

    private var server: LoopbackRedirectServer?

    override func tearDown() async throws {
        await server?.stop()
        server = nil
        try await super.tearDown()
    }

    /// Requests must go out over a session that ignores any system proxy,
    /// or a configured proxy would swallow the loopback request.
    private func makeDirectSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }

    private func startServer() async throws -> LoopbackRedirectServer {
        let server = try await LoopbackRedirectServer.bind()
        self.server = server
        return server
    }

    func testRedirectURIUsesABoundCandidatePort() async throws {
        let server = try await startServer()

        XCTAssertTrue(LoopbackRedirectServer.candidatePorts.contains(server.port))
        XCTAssertEqual(
            server.redirectURI,
            "http://127.0.0.1:\(server.port)/callback"
        )
    }

    func testDeliversCodeAndState() async throws {
        let server = try await startServer()
        let session = makeDirectSession()

        // Start waiting before the request is fired.
        let pending = Task { try await server.waitForCallback(timeout: 15) }

        let url = try XCTUnwrap(
            URL(string: "\(server.redirectURI)?code=test-code-123&state=test-state-abc")
        )
        let (body, response) = try await session.data(from: url)

        let callback = try await pending.value
        XCTAssertEqual(callback.code, "test-code-123")
        XCTAssertEqual(callback.state, "test-state-abc")

        // The browser should land on a real page, not a blank socket close.
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(body.isEmpty, "Expected an HTML page for the browser")
    }

    /// Percent-encoded values must survive the round trip intact.
    func testDecodesPercentEncodedParameters() async throws {
        let server = try await startServer()
        let session = makeDirectSession()

        let pending = Task { try await server.waitForCallback(timeout: 15) }

        let url = try XCTUnwrap(
            URL(string: "\(server.redirectURI)?code=abc%2Fdef%2Bghi&state=s%3D1")
        )
        _ = try? await session.data(from: url)

        let callback = try await pending.value
        XCTAssertEqual(callback.code, "abc/def+ghi")
        XCTAssertEqual(callback.state, "s=1")
    }

    /// Hitting Cancel on Spotify's consent screen redirects with `?error=`.
    func testSurfacesAuthorizationDenial() async throws {
        let server = try await startServer()
        let session = makeDirectSession()

        let pending = Task { try await server.waitForCallback(timeout: 15) }

        let url = try XCTUnwrap(URL(string: "\(server.redirectURI)?error=access_denied"))
        _ = try? await session.data(from: url)

        do {
            _ = try await pending.value
            XCTFail("Expected an authorization failure")
        } catch let failure as LoopbackRedirectServer.Failure {
            guard case .authorizationDenied(let reason) = failure else {
                return XCTFail("Expected .authorizationDenied, got \(failure)")
            }
            XCTAssertEqual(reason, "access_denied")
        }
    }

    func testTimesOutRatherThanHangingForever() async throws {
        let server = try await startServer()

        do {
            _ = try await server.waitForCallback(timeout: 1)
            XCTFail("Expected a timeout")
        } catch let failure as LoopbackRedirectServer.Failure {
            XCTAssertEqual(failure, .timedOut)
        }
    }

    /// `stop()` (menu-bar cancel, or app quit mid-sign-in) must release the
    /// waiter instead of leaking its continuation.
    func testStopReleasesTheWaiter() async throws {
        let server = try await startServer()

        let pending = Task { try await server.waitForCallback(timeout: 30) }
        await server.stop()

        do {
            _ = try await pending.value
            XCTFail("Expected cancellation")
        } catch let failure as LoopbackRedirectServer.Failure {
            XCTAssertEqual(failure, .cancelled)
        }
    }

    /// Two servers cannot hold the same port, so the second must fall through
    /// to the next candidate — the reason three URIs are registered.
    func testSecondServerFallsThroughToAnotherPort() async throws {
        let first = try await startServer()
        let second = try await LoopbackRedirectServer.bind()
        defer { Task { await second.stop() } }

        XCTAssertNotEqual(first.port, second.port)
        XCTAssertTrue(LoopbackRedirectServer.candidatePorts.contains(second.port))
    }
}
