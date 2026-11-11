import Foundation
#if canImport(StoreKit)
import StoreKit
#endif
#if canImport(AdServices) && (os(iOS) || os(macOS))
import AdServices
#endif

/// A flat JSON value for event properties and feedback data/metadata.
/// Literals work directly: `["step": "welcome", "index": 0, "skipped": false]`.
public enum PropertyValue: Sendable, Equatable, Codable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral
{
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        }
    }
}

/// What kind of feedback the user is sending.
public enum FeedbackKind: String, Sendable, CaseIterable {
    case bug, idea, question, praise
}

/// Outcome of `RevenueHog.sendFeedback`. Never thrown, always returned.
public enum FeedbackResult: Sendable, Equatable {
    /// Stored by RevenueHog; `id` is the server's feedback id when it sent one.
    case sent(id: String?)
    /// Offline or rate limited: persisted and delivered on a later flush or launch.
    case queued
    /// Invalid input, or a request the server will never accept. Not retried.
    case rejected(reason: String)
}

/// One `track` call, buffered on disk until it goes out in a batch.
struct BufferedEvent: Codable, Equatable {
    var name: String
    var properties: [String: PropertyValue]?
    /// Client timestamp, epoch milliseconds.
    var at: Int64
    var appUserId: String
}

/// Body for `POST /api/sdk/v1/events` (max 50 events).
struct EventBatchPayload: Encodable {
    var bundleId: String
    var platform: String
    var events: [BufferedEvent]
}

/// Body for `POST /api/sdk/v1/feedback`.
struct FeedbackPayload: Encodable {
    var bundleId: String
    var platform: String
    var appUserId: String
    var kind: String
    var message: String
    var rating: Int?
    var data: [String: PropertyValue]?
    var metadata: [String: PropertyValue]?
}

/// Body for `POST /api/sdk/v1/adservices`.
struct AdServicesPayload: Encodable {
    var bundleId: String
    var platform: String
    var installId: String
    var token: String
    var environment: String
    var appVersion: String?
    var storefront: String?
}

/// Client-side mirrors of the server's validation, so bad input is caught
/// (and logged) on device instead of being dropped by a 400.
enum EventRules {
    static let maxBatch = 50
    static let batchThreshold = 20
    static let maxBuffered = 1_000
    static let maxPropertiesBytes = 2_048
    static let maxFeedbackMessage = 5_000
    static let maxFeedbackJSONBytes = 8_192

    /// snake_case, starts with a letter, max 48 chars, `rh_` is reserved.
    static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 48, !name.hasPrefix("rh_"),
              let first = name.unicodeScalars.first, ("a"..."z").contains(first),
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" })
        else { return nil }
        return name
    }

    static func jsonSize(_ value: some Encodable) -> Int {
        (try? JSONEncoder().encode(value).count) ?? Int.max
    }
}

/// Default AdServices and storefront readers. Both are best-effort and
/// return nil wherever the framework or API is unavailable.
enum AdServicesSource {
    @Sendable static func token() async -> String? {
        #if canImport(AdServices) && (os(iOS) || os(macOS))
        if #available(iOS 14.3, macOS 11.1, *) {
            return try? AAAttribution.attributionToken()
        }
        #endif
        return nil
    }

    @Sendable static func storefront() async -> String? {
        #if canImport(StoreKit) && !os(watchOS)
        return await Storefront.current?.countryCode
        #else
        return nil
        #endif
    }
}

extension HogClient {
    // MARK: - Events

    func track(_ rawName: String, properties: [String: PropertyValue]?) async {
        guard let name = EventRules.validName(rawName) else {
            log.warn("track: invalid event name \"\(rawName)\" (snake_case, max 48 chars, no rh_ prefix), dropped")
            return
        }
        var props = properties
        if let p = props, EventRules.jsonSize(p) > EventRules.maxPropertiesBytes {
            log.warn("track(\(name)): properties over \(EventRules.maxPropertiesBytes) bytes, sent without them")
            props = nil
        }
        var buffer = storage.eventBuffer
        buffer.append(BufferedEvent(
            name: name,
            properties: props?.isEmpty == true ? nil : props,
            at: Int64(now().timeIntervalSince1970 * 1000),
            appUserId: appUserId
        ))
        if buffer.count > EventRules.maxBuffered {
            buffer.removeFirst(buffer.count - EventRules.maxBuffered)
        }
        storage.eventBuffer = buffer
        if buffer.count >= EventRules.batchThreshold {
            await flushEvents()
        } else {
            scheduleEventFlush()
        }
    }

    /// Moves the buffer into batches of at most 50 and sends each one. A
    /// batch that cannot be delivered lands in the persistent request queue.
    func flushEvents() async {
        eventFlushTask?.cancel()
        eventFlushTask = nil
        while true {
            let buffer = storage.eventBuffer
            guard !buffer.isEmpty else { return }
            let batch = Array(buffer.prefix(EventRules.maxBatch))
            storage.eventBuffer = Array(buffer.dropFirst(batch.count))
            let payload = EventBatchPayload(
                bundleId: device.bundleId, platform: device.platform, events: batch
            )
            guard let body = try? Payloads.encoder.encode(payload) else { continue }
            if await deliver(path: "/api/sdk/v1/events", body: body, attempts: 3) {
                continue
            }
            queue.append(PendingRequest(path: "/api/sdk/v1/events", body: body))
            log.info("queued /api/sdk/v1/events for later delivery")
        }
    }

    private func scheduleEventFlush() {
        guard eventFlushTask == nil else { return }
        let delay = eventFlushDelay
        eventFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.eventFlushTimerFired()
        }
    }

    private func eventFlushTimerFired() async {
        eventFlushTask = nil
        await flushEvents()
    }

    // MARK: - Feedback

    func sendFeedback(
        kind: FeedbackKind,
        message: String,
        rating: Int?,
        data: [String: PropertyValue]?,
        metadata: [String: PropertyValue]?
    ) async -> FeedbackResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return reject("message is required") }
        guard text.count <= EventRules.maxFeedbackMessage else {
            return reject("message is too long (max \(EventRules.maxFeedbackMessage))")
        }
        if let rating, !(1...5).contains(rating) {
            return reject("rating must be an integer from 1 to 5")
        }
        // Device context rides in metadata; the app's own keys win.
        var meta: [String: PropertyValue] = [:]
        if let v = device.osVersion { meta["osVersion"] = .string(v) }
        if let v = device.deviceModel { meta["deviceModel"] = .string(v) }
        if let v = device.locale { meta["locale"] = .string(v) }
        if let v = device.appVersion { meta["appVersion"] = .string(v) }
        meta.merge(metadata ?? [:]) { _, app in app }
        if let data, EventRules.jsonSize(data) > EventRules.maxFeedbackJSONBytes {
            return reject("data is too large (max \(EventRules.maxFeedbackJSONBytes) bytes)")
        }
        if EventRules.jsonSize(meta) > EventRules.maxFeedbackJSONBytes {
            return reject("metadata is too large (max \(EventRules.maxFeedbackJSONBytes) bytes)")
        }
        let payload = FeedbackPayload(
            bundleId: device.bundleId,
            platform: device.platform,
            appUserId: appUserId,
            kind: kind.rawValue,
            message: text,
            rating: rating,
            data: data,
            metadata: meta.isEmpty ? nil : meta
        )
        guard let body = try? Payloads.encoder.encode(payload) else {
            return reject("could not encode feedback")
        }
        let path = "/api/sdk/v1/feedback"
        guard let response = await deliverResponse(path: path, body: body, attempts: 3) else {
            queue.append(PendingRequest(path: path, body: body))
            log.info("queued \(path) for later delivery")
            return .queued
        }
        guard (200..<300).contains(response.status) else {
            return .rejected(reason: "HTTP \(response.status)")
        }
        await flush()
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        return .sent(id: json?["id"] as? String)
    }

    private func reject(_ reason: String) -> FeedbackResult {
        log.warn("sendFeedback: \(reason)")
        return .rejected(reason: reason)
    }

    // MARK: - AdServices

    /// Captures the Apple Ads token once per install. A launch without a
    /// token (framework missing, transient error) simply tries next launch.
    func sendAdServicesTokenIfNeeded() async {
        guard !storage.adServicesSent else { return }
        // Already waiting in the queue: flush() sets the flag when it lands.
        // If the queue later evicts it, the flag stays unset and the next
        // launch captures the token again.
        guard !queue.load().contains(where: { $0.path == Self.adServicesPath }) else { return }
        guard let token = await adServicesToken(), !token.isEmpty else {
            log.debug("no AdServices token this launch")
            return
        }
        let payload = AdServicesPayload(
            bundleId: device.bundleId,
            platform: device.platform,
            installId: storage.installId,
            token: token,
            environment: adServicesEnvironment,
            appVersion: device.appVersion,
            storefront: await storefront()
        )
        guard let body = try? Payloads.encoder.encode(payload) else { return }
        // The flag is set only once the server answered (2xx, or a permanent
        // rejection it will never accept). A queued send sets it on flush.
        if await deliver(path: Self.adServicesPath, body: body, attempts: 3) {
            storage.adServicesSent = true
            await flush()
        } else {
            queue.append(PendingRequest(path: Self.adServicesPath, body: body))
            log.info("queued \(Self.adServicesPath) for later delivery")
        }
    }

    static let adServicesPath = "/api/sdk/v1/adservices"

    /// 'production' | 'sandbox' | 'debug', from StoreKit's environment when
    /// resolved, else the build configuration.
    var adServicesEnvironment: String {
        switch storeEnvironment {
        case "Sandbox": return "sandbox"
        case "Xcode": return "debug"
        case "Production": return "production"
        default:
            #if DEBUG
            return "debug"
            #else
            return "production"
            #endif
        }
    }
}
