import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// What came back from the server. identify/attribute only look at the
/// status; the attestation endpoints also read the JSON body.
struct TransportResponse: Sendable {
    var status: Int
    var body: Data
}

/// Minimal HTTP seam so tests can run without a network.
protocol Transport: Sendable {
    /// POSTs `body` and returns the response. Throws on transport
    /// (network) failure only. HTTP error statuses are returned, not thrown.
    func post(url: URL, body: Data, headers: [String: String]) async throws -> TransportResponse
}

struct URLSessionTransport: Transport {
    var session: URLSession = .shared

    func post(url: URL, body: Data, headers: [String: String]) async throws -> TransportResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        return TransportResponse(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            body: data
        )
    }
}
