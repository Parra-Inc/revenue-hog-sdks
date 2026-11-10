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

    /// GETs `url` (config reads such as the churn survey). Same error
    /// contract as `post`.
    func get(url: URL, headers: [String: String]) async throws -> TransportResponse
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
        return try await perform(request)
    }

    func get(url: URL, headers: [String: String]) async throws -> TransportResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> TransportResponse {
        let (data, response) = try await session.data(for: request)
        return TransportResponse(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0,
            body: data
        )
    }
}
