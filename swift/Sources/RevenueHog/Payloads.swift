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

/// Body for `POST /api/sdk/v1/attribute`.
struct AttributePayload: Codable, Equatable {
    var appUserId: String
    var bundleId: String
    var originalTransactionId: String
    var productId: String?
}

/// A request that couldn't be delivered yet — persisted to disk and
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
