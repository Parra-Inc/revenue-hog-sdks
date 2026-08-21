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

/// Body for `POST /api/sdk/v1/paywall`. `environment` is StoreKit's
/// AppTransaction environment (omitted until resolved; the server reads an
/// absent value as Production). `forceVariant` is the QA preview path,
/// honored server-side only for non-Production environments.
struct PaywallRequestPayload: Codable, Equatable {
    var appUserId: String
    var bundleId: String
    var entitlement: String
    var environment: String?
    var forceVariant: String?
    var installId: String
}

/// Response from `POST /api/sdk/v1/paywall`. Everything is optional so a
/// future field change can never make the money path throw; an empty or
/// undecodable answer resolves to the compiled-in fallback.
struct PaywallResponsePayload: Decodable {
    struct WireSku: Decodable {
        var productId: String
        var kind: String
    }

    var entitlement: String?
    var skus: [WireSku]?
    var experimentId: String?
    var variantKey: String?
    var forced: Bool?
    var ttlSeconds: Int?
}

/// Body for `POST /api/sdk/v1/paywall/impression`.
struct PaywallImpressionPayload: Codable, Equatable {
    var bundleId: String
    var experimentId: String
    var installId: String
    var renderedSkus: [String]
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
