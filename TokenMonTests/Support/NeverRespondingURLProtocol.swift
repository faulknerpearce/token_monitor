import Foundation

/// Accepts every request and never answers, so only cancellation ends it.
final class NeverRespondingURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}

    /// An ephemeral session whose requests never complete.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NeverRespondingURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}
