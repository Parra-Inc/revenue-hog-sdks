import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP seam so tests can run without a network.
protocol Transport: Sendable {
    /// POSTs `body` and returns the HTTP status code. Throws on transport
    /// (network) failure only — HTTP error statuses are returned, not thrown.
    func post(url: URL, body: Data, headers: [String: String]) async throws -> Int
}

struct URLSessionTransport: Transport {
    var session: URLSession = .shared

    func post(url: URL, body: Data, headers: [String: String]) async throws -> Int {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
