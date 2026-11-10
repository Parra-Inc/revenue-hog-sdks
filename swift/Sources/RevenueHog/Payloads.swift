import Foundation

/// Body for `POST /api/sdk/v1/identify`. `anonymousAppUserId` is the
/// pre-login `$anon_` id, sent on the first identify so the server folds that
/// customer (and its opens) into the real user id.
struct IdentifyPayload: Codable, Equatable {
    var appUserId: String
    var bundleId: String
    var platform: String
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
    var attributes: [String: String]?
    var anonymousAppUserId: String? = nil
}

/// Body for `POST /api/sdk/v1/open`, the once-a-day open ping that makes
/// everyone who opens the app a customer, not only subscribers.
struct OpenPayload: Codable, Equatable {
    var appUserId: String
    var bundleId: String
    var platform: String
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
}

/// Response from `GET /api/sdk/v1/churn-survey`. Everything is optional so a
/// server change can never crash the host app; an undecodable answer means
/// "no survey".
struct ChurnSurveyResponsePayload: Decodable {
    struct WireOption: Decodable {
        var key: String
        var title: String
    }

    struct WireOther: Decodable {
        var enabled: Bool?
        var placeholder: String?
    }

    struct WireTrigger: Decodable {
        var onAutoRenewOff: Bool?
        var maxPerUserDays: Int?
    }

    struct WireSurvey: Decodable {
        var version: Int?
        var title: String?
        var options: [WireOption]?
        var other: WireOther?
        var randomize: Bool?
        var allowAdditionalInfo: Bool?
        var trigger: WireTrigger?
        var sampleRate: Double?
    }

    var survey: WireSurvey?
    var show: Bool?
    var reason: String?
}

/// Body for `POST /api/sdk/v1/churn-survey/response`. Exactly one of
/// `optionKey`, `otherText` or `skipped`. `shownOrder` is the order the
/// options were really rendered in, "other" last.
struct ChurnAnswerPayload: Codable, Equatable {
    var bundleId: String
    var platform: String
    var appUserId: String
    var responseId: String
    var optionKey: String?
    var otherText: String?
    /// Optional text that goes with any answer; only when the survey allows it.
    var additionalInfo: String?
    var skipped: Bool?
    var surveyVersion: Int
    var shownOrder: [String]
    var productId: String?
    var store: String?
    var environment: String?
    var occurredAt: String
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
