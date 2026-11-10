import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// One choice in the churn survey.
public struct ChurnSurveyOption: Equatable, Sendable, Identifiable {
    /// Stable key from the dashboard (for example `too_expensive`).
    public let key: String
    /// Localized title to show.
    public let title: String
    public var id: String { key }
}

/// The churn survey as it should render: options already in display order
/// (shuffled when the dashboard says so), with "Other" always last.
public struct ChurnSurvey: Equatable, Sendable {
    public let version: Int
    public let title: String
    public let options: [ChurnSurveyOption]
    public let otherEnabled: Bool
    public let otherPlaceholder: String
    /// Option keys in the order shown, "other" last when enabled. Sent back
    /// with the answer so position bias can be measured.
    public let shownOrder: [String]
    let autoRenewTrigger: Bool
    let maxPerUserDays: Int
}

/// What happened when the survey was presented.
public enum ChurnSurveyResult: Equatable, Sendable {
    /// The user picked one of the configured options.
    case option(String)
    /// The user picked "Other" and wrote this text.
    case other(String)
    /// The survey appeared and was dismissed without an answer.
    case skipped
    /// Nothing appeared: no survey configured, disabled, outside the sample,
    /// shown too recently, no window to present on, or the SDK is not
    /// configured.
    case notShown
}

/// Button labels for the built-in survey, from the package bundle's
/// `Localizable.strings` (17 locales, English fallback). The server payload
/// does not carry these labels today; titles, options and the "Other"
/// placeholder already come localized from the server.
enum ChurnSurveyStrings {
    static var other: String { localized("churn_survey.other", "Other") }
    static var skip: String { localized("churn_survey.skip", "Skip") }
    static var send: String { localized("churn_survey.send", "Send") }

    /// The label for `key` in `localization` (an lproj name such as `de`),
    /// or in the user's preferred language when nil.
    static func localized(_ key: String, _ fallback: String, localization: String? = nil) -> String {
        var bundle = Bundle.module
        if let localization,
           let path = Bundle.module.path(forResource: localization, ofType: "lproj"),
           let specific = Bundle(path: path) {
            bundle = specific
        }
        return bundle.localizedString(forKey: key, value: fallback, table: nil)
    }
}

/// Pure survey rules, kept free of networking and UI so they are unit tested.
enum ChurnSurveyRules {
    static let otherKey = "other"
    static let defaultMaxPerUserDays = 90

    /// The render order: options shuffled when `randomize` is on (Fisher-Yates
    /// over a copy), with "Other" never shuffled and always last.
    static func order<G: RandomNumberGenerator>(
        _ options: [ChurnSurveyOption],
        randomize: Bool,
        using generator: inout G
    ) -> [ChurnSurveyOption] {
        let live = options.filter { $0.key != otherKey }
        return randomize ? live.shuffled(using: &generator) : live
    }

    static func shownOrder(_ options: [ChurnSurveyOption], otherEnabled: Bool) -> [String] {
        options.map(\.key) + (otherEnabled ? [otherKey] : [])
    }

    /// True while the last appearance is inside the frequency cap window.
    /// A cap of 0 days means no cap.
    static func isCapped(lastShownAt: Date?, now: Date, maxPerUserDays: Int) -> Bool {
        guard let lastShownAt, maxPerUserDays > 0 else { return false }
        return now.timeIntervalSince(lastShownAt) < Double(maxPerUserDays) * 86_400
    }

    /// 32-bit FNV-1a, identical to the server's, so a user lands on the same
    /// side of the sample rate everywhere.
    static func fnv1a(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811c_9dc5
        for unit in s.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    /// Deterministic sampling by seed. Only used when the server answer has
    /// no `show` decision of its own (older servers); otherwise the server,
    /// which seeds with the app id too, has already sampled.
    static func inSample(_ sampleRate: Double, seed: String) -> Bool {
        if sampleRate >= 1 { return true }
        if sampleRate <= 0 { return false }
        return Double(fnv1a(seed)) / 4_294_967_296 < sampleRate
    }

    /// Builds the renderable survey from the wire answer, or nil when there is
    /// nothing worth showing.
    static func survey<G: RandomNumberGenerator>(
        from wire: ChurnSurveyResponsePayload.WireSurvey,
        using generator: inout G
    ) -> ChurnSurvey? {
        let options = (wire.options ?? [])
            .filter { !$0.key.isEmpty && !$0.title.isEmpty }
            .map { ChurnSurveyOption(key: $0.key, title: $0.title) }
        let otherEnabled = wire.other?.enabled ?? false
        guard !options.isEmpty || otherEnabled else { return nil }
        let ordered = order(options, randomize: wire.randomize ?? false, using: &generator)
        return ChurnSurvey(
            version: max(wire.version ?? 1, 1),
            title: wire.title ?? "Why are you leaving?",
            options: ordered,
            otherEnabled: otherEnabled,
            otherPlaceholder: wire.other?.placeholder ?? "Tell us more",
            shownOrder: shownOrder(ordered, otherEnabled: otherEnabled),
            autoRenewTrigger: wire.trigger?.onAutoRenewOff ?? true,
            maxPerUserDays: wire.trigger?.maxPerUserDays ?? defaultMaxPerUserDays
        )
    }

    /// Original transaction ids that newly need the survey: auto-renew is off
    /// and they have not triggered it yet. Also returns the handled set with
    /// ids whose auto-renew came back on removed, so a later cancel counts.
    static func newlyCancelled(
        renewals: [(originalId: String, willAutoRenew: Bool)],
        handled: Set<String>
    ) -> (fresh: [String], handled: Set<String>) {
        var next = handled
        var fresh: [String] = []
        for r in renewals {
            if r.willAutoRenew {
                next.remove(r.originalId)
            } else if !next.contains(r.originalId) {
                fresh.append(r.originalId)
            }
        }
        return (fresh, next)
    }
}

// MARK: - Client logic

extension HogClient {
    /// Fetches the survey for this user and applies the client-side gates.
    /// Nil means "do not show". `ignoreTrigger` is for manual calls, which
    /// show whether or not the auto-renew trigger is on.
    func churnSurvey(ignoreTrigger: Bool = true) async -> ChurnSurvey? {
        guard let wire = await fetchChurnSurvey(), let wireSurvey = wire.survey else { return nil }
        var rng = SystemRandomNumberGenerator()
        guard let survey = ChurnSurveyRules.survey(from: wireSurvey, using: &rng) else { return nil }
        if let show = wire.show {
            if !show {
                log.debug("churn survey not shown: \(wire.reason ?? "server said no")")
                return nil
            }
        } else if !ChurnSurveyRules.inSample(wireSurvey.sampleRate ?? 1, seed: appUserId) {
            return nil
        }
        if !ignoreTrigger && !survey.autoRenewTrigger { return nil }
        if ChurnSurveyRules.isCapped(
            lastShownAt: storage.churnSurveyShownAt, now: now(), maxPerUserDays: survey.maxPerUserDays
        ) {
            log.debug("churn survey shown recently on this device, skipped")
            return nil
        }
        return survey
    }

    /// Stamps the local frequency cap. Called as the survey appears.
    func churnSurveyShown() {
        storage.churnSurveyShownAt = now()
    }

    /// Records the answer (or the skip). Queued and retried like identify;
    /// `responseId` makes replays idempotent on the server.
    func submitChurnSurvey(_ survey: ChurnSurvey, result: ChurnSurveyResult, productId: String?) async {
        var optionKey: String?
        var otherText: String?
        var skipped: Bool?
        switch result {
        case .option(let key): optionKey = key
        case .other(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { skipped = true } else { otherText = String(trimmed.prefix(1000)) }
        case .skipped: skipped = true
        case .notShown: return
        }
        let payload = ChurnAnswerPayload(
            bundleId: device.bundleId,
            platform: device.platform,
            appUserId: appUserId,
            responseId: UUID().uuidString.lowercased(),
            optionKey: optionKey,
            otherText: otherText,
            skipped: skipped,
            surveyVersion: survey.version,
            shownOrder: survey.shownOrder,
            productId: productId,
            store: device.platform == "android" ? "google" : "apple",
            environment: storeEnvironment,
            occurredAt: ISO8601DateFormatter().string(from: now())
        )
        await send("/api/sdk/v1/churn-survey/response", payload)
    }

    private func fetchChurnSurvey() async -> ChurnSurveyResponsePayload? {
        var components = URLComponents(
            url: options.baseURL.appendingPathComponent("/api/sdk/v1/churn-survey"),
            resolvingAgainstBaseURL: false
        )
        var query = [
            URLQueryItem(name: "bundleId", value: device.bundleId),
            URLQueryItem(name: "platform", value: device.platform),
            URLQueryItem(name: "appUserId", value: appUserId),
        ]
        if let locale = device.locale { query.append(URLQueryItem(name: "locale", value: locale)) }
        components?.queryItems = query
        guard let url = components?.url else { return nil }
        let headers = await requestHeaders()
        do {
            let response = try await transport.get(url: url, headers: headers)
            guard (200..<300).contains(response.status) else {
                log.warn("\(response.status) from /api/sdk/v1/churn-survey")
                return nil
            }
            return try? JSONDecoder().decode(ChurnSurveyResponsePayload.self, from: response.body)
        } catch {
            log.debug("network error on /api/sdk/v1/churn-survey: \(error.localizedDescription)")
            return nil
        }
    }

    /// Auto-renew states of this user's current subscriptions, from StoreKit.
    /// Returns the subscriptions whose auto-renew newly turned off, with a
    /// product id, and updates the handled set.
    func claimNewlyCancelledSubscription() async -> (originalId: String, productId: String)? {
        #if canImport(StoreKit)
        let renewals = await Self.currentRenewalStates()
        let result = ChurnSurveyRules.newlyCancelled(
            renewals: renewals.map { ($0.originalId, $0.willAutoRenew) },
            handled: storage.churnSurveyHandled
        )
        storage.churnSurveyHandled = result.handled
        guard let first = result.fresh.first,
              let match = renewals.first(where: { $0.originalId == first })
        else { return nil }
        return (first, match.productId)
        #else
        return nil
        #endif
    }

    func markSubscriptionHandled(_ originalId: String) {
        var handled = storage.churnSurveyHandled
        handled.insert(originalId)
        storage.churnSurveyHandled = handled
    }

    #if canImport(StoreKit)
    private static func currentRenewalStates() async -> [(originalId: String, productId: String, willAutoRenew: Bool)] {
        guard #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *) else { return [] }
        var out: [(String, String, Bool)] = []
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  transaction.productType == .autoRenewable,
                  let product = try? await Product.products(for: [transaction.productID]).first,
                  let statuses = try? await product.subscription?.status
            else { continue }
            for status in statuses {
                guard case .verified(let renewal) = status.renewalInfo,
                      case .verified(let statusTxn) = status.transaction,
                      statusTxn.originalID == transaction.originalID
                else { continue }
                out.append((String(transaction.originalID), transaction.productID, renewal.willAutoRenew))
            }
        }
        return out
    }
    #endif
}
