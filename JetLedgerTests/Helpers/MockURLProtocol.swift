import Foundation

/// Test-only URL protocol that lets a test stub a single HTTP round-trip via
/// the `handler` closure.
///
/// **Usage constraint:** the `handler` is a process-wide static. Test suites
/// that use `MockURLProtocol` MUST be marked `@Suite(.serialized)` — running
/// them in parallel races the static. Call `MockURLProtocol.reset()` at the
/// start of each test to clear stale state.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Clears the stubbed handler. Call at the start of each test.
    static func reset() {
        handler = nil
    }
}
