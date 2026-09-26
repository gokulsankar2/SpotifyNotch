//
//  StubURLProtocol.swift
//  SpotifyNotchTests
//
//  A URLProtocol that answers requests from a queue of canned responses and
//  records what was asked, so SpotifyAPIClient can be tested without network.
//

import Foundation

final class StubURLProtocol: URLProtocol {

    struct Response {
        var statusCode: Int
        var body: Data
        var headers: [String: String]

        init(statusCode: Int = 200, body: Data = Data(), headers: [String: String] = [:]) {
            self.statusCode = statusCode
            self.body = body
            self.headers = headers
        }

        static func json(_ string: String, statusCode: Int = 200) -> Response {
            Response(
                statusCode: statusCode,
                body: Data(string.utf8),
                headers: ["Content-Type": "application/json"]
            )
        }
    }

    /// Guarded by `lock`; `URLProtocol` instances are created by URLSession on
    /// arbitrary threads, so this cannot be plain static mutable state.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queued: [Response] = []
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        queued = []
        recorded = []
    }

    static func enqueue(_ response: Response) {
        lock.lock(); defer { lock.unlock() }
        queued.append(response)
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    private static func next(for request: URLRequest) -> Response {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        guard !queued.isEmpty else { return Response(statusCode: 500) }
        return queued.removeFirst()
    }

    /// Builds a session wired to this stub. `.ephemeral` keeps any real
    /// cache or cookie store out of the test.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.next(for: request)

        if let url = request.url,
           let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
           ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }

        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
