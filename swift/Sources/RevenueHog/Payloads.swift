import Foundation

/// Body for `POST /api/sdk/v1/identify`.
struct IdentifyPayload: Codable, Equatable {
    var appUserId: String
    var bundleId: String
    var platform: String
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
    var attributes: [String: String]?
}

/// Body for `POST /api/sdk/v1/attribute`. `jws` is the StoreKit 2 signed
/// transaction (`VerificationResult.jwsRepresentation`); the server
/// verifies it independently of device auth.
struct AttributePayload: Codable, Equatable {
    var appUserId: String
    var bundleId: String
    var originalTransactionId: String
    var productId: String?
    var jws: String?
}

/// Body for `POST /api/sdk/v1/attest`.
struct AttestPayload: Codable, Equatable {
    var keyId: String
    var attestation: String
    var challenge: String
    var bundleId: String
}

/// Response from `POST /api/sdk/v1/attest/challenge`.
struct AttestChallengeResponse: Decodable {
    var challenge: String
}

/// Response from `POST /api/sdk/v1/attest`.
struct AttestResponse: Decodable {
    var deviceToken: String
}

/// A request that couldn't be delivered yet, persisted to disk and
/// replayed by `HogClient.flush()`. Both endpoints are idempotent, so
/// replays are safe.
struct PendingRequest: Codable, Equatable {
    var path: String
    var body: Data
}

enum Payloads {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
