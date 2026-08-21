import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// One SKU in a server-decided paywall menu, in render order.
public struct PaywallSku: Equatable, Sendable {
    /// What the product is, per the dashboard config. `.unknown` on
    /// compiled-in fallback entries (the SDK cannot know) and on wire
    /// values newer than this SDK.
    public enum Kind: String, Sendable {
        case subscription
        case iap
        case unknown
    }

    public let productId: String
    public let kind: Kind
}

/// The answer to "which SKUs should this paywall offer": an ORDERED list.
/// Render it in this order; under an experiment the order is part of what
/// is being tested. This type is always produced, never thrown past: on any
/// failure it carries the compiled-in fallback with `isFallback == true`.
public struct Paywall: Equatable, Sendable {
    public let entitlement: String
    /// Ordered menu. Load through StoreKit and re-sort to this order (or
    /// use `products()`, which does both).
    public let skus: [PaywallSku]
    /// Present while an A/B experiment is serving this install.
    public let experimentId: String?
    /// This install's variant, for the app's own analytics.
    public let variantKey: String?
    /// True when this is the compiled-in fallback list: the server was
    /// unreachable, answered empty, or the SDK is not configured.
    public let isFallback: Bool

    /// The ordered product ids, ready for `Product.products(for:)`.
    public var productIds: [String] { skus.map(\.productId) }

    static func fallback(entitlement: String, productIds: [String]) -> Paywall {
        Paywall(
            entitlement: entitlement,
            skus: productIds.map { PaywallSku(productId: $0, kind: .unknown) },
            experimentId: nil,
            variantKey: nil,
            isFallback: true
        )
    }
}

#if canImport(StoreKit)
extension Paywall {
    /// Loads the menu's products and returns them IN MENU ORDER.
    /// `Product.products(for:)` returns products unordered, and under an
    /// experiment the order is part of the treatment, so never render
    /// StoreKit's return order directly.
    @available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
    public func products() async throws -> [Product] {
        let loaded = try await Product.products(for: productIds)
        var order: [String: Int] = [:]
        for (index, sku) in skus.enumerated() where order[sku.productId] == nil {
            order[sku.productId] = index
        }
        return loaded.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }
}
#endif

// MARK: - Client logic

/// Cached per entitlement in the defaults store: the last good answer, when
/// it was fetched, and for which app user (an identity change invalidates).
struct CachedPaywall: Codable, Equatable {
    var entitlement: String
    var productIds: [String]
    var kinds: [String]
    var experimentId: String?
    var variantKey: String?
    var ttlSeconds: Int
    var fetchedAt: Date
    var appUserId: String

    var paywall: Paywall {
        Paywall(
            entitlement: entitlement,
            skus: zip(productIds, kinds).map {
                PaywallSku(productId: $0, kind: PaywallSku.Kind(rawValue: $1) ?? .unknown)
            },
            experimentId: experimentId,
            variantKey: variantKey,
            isFallback: productIds.isEmpty
        )
    }
}

extension HogClient {
    /// The paywall is the money path, so this resolves FAST and never
    /// fails: fresh cache -> network (short timeout, no enrollment wait) ->
    /// stale cache -> compiled-in fallback. An empty server answer (unknown
    /// entitlement, unresolvable bundle id) also means the fallback.
    func paywall(
        entitlement rawEntitlement: String,
        fallback: [String],
        forceVariant: String? = nil
    ) async -> Paywall {
        let entitlement = rawEntitlement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entitlement.isEmpty else {
            log.warn("paywall called with an empty entitlement, serving the fallback")
            return .fallback(entitlement: rawEntitlement, productIds: fallback)
        }

        let user = appUserId
        let cached = storage.paywallCache[entitlement]
        if forceVariant == nil,
           let cached,
           cached.appUserId == user,
           Date().timeIntervalSince(cached.fetchedAt) < Double(cached.ttlSeconds) {
            log.debug("paywall(\(entitlement)) served from cache")
            return resolved(cached.paywall, fallback: fallback)
        }

        let payload = PaywallRequestPayload(
            appUserId: user,
            bundleId: device.bundleId,
            entitlement: entitlement,
            environment: storeEnvironment,
            forceVariant: forceVariant,
            installId: storage.installId
        )
        if let response = await fetchPaywall(payload) {
            let paywall = Paywall(
                entitlement: response.entitlement ?? entitlement,
                skus: (response.skus ?? []).map {
                    PaywallSku(productId: $0.productId, kind: PaywallSku.Kind(rawValue: $0.kind) ?? .unknown)
                },
                experimentId: response.experimentId,
                variantKey: response.variantKey,
                isFallback: (response.skus ?? []).isEmpty
            )
            // Forced previews are QA-only: never cached, never the real menu.
            if forceVariant == nil {
                var cache = storage.paywallCache
                cache[entitlement] = CachedPaywall(
                    entitlement: entitlement,
                    productIds: paywall.skus.map(\.productId),
                    kinds: paywall.skus.map(\.kind.rawValue),
                    experimentId: paywall.experimentId,
                    variantKey: paywall.variantKey,
                    ttlSeconds: min(max(response.ttlSeconds ?? 3600, 60), 86_400),
                    fetchedAt: Date(),
                    appUserId: user
                )
                storage.paywallCache = cache
            }
            return resolved(paywall, fallback: fallback)
        }

        // Network failure: stale beats empty, however old (the config the
        // user last saw is a better guess than nothing).
        if let cached {
            log.info("paywall(\(entitlement)) network failed, serving stale cache")
            return resolved(cached.paywall, fallback: fallback)
        }
        log.info("paywall(\(entitlement)) unreachable with no cache, serving the fallback")
        return .fallback(entitlement: entitlement, productIds: fallback)
    }

    /// Display-time truth: call when the paywall actually APPEARS, after
    /// StoreKit product loading, with the product ids that really rendered.
    /// Fetching assigns; impressions expose. No-op outside an experiment.
    func paywallShown(_ paywall: Paywall, rendered: [String]) async {
        guard let experimentId = paywall.experimentId else { return }
        let payload = PaywallImpressionPayload(
            bundleId: device.bundleId,
            experimentId: experimentId,
            installId: storage.installId,
            renderedSkus: Array(rendered.prefix(50))
        )
        guard let body = try? Payloads.encoder.encode(payload) else { return }
        // Best-effort, bounded, never queued: a replayed impression hours
        // later would count an exposure that may never have happened.
        _ = await deliver(path: "/api/sdk/v1/paywall/impression", body: body, attempts: 2)
    }

    /// A server answer with SKUs passes through; an empty one becomes the
    /// caller's compiled-in fallback (the never-blank contract).
    private func resolved(_ paywall: Paywall, fallback: [String]) -> Paywall {
        guard paywall.skus.isEmpty else { return paywall }
        return .fallback(entitlement: paywall.entitlement, productIds: fallback)
    }

    /// One attempt, short deadline, and NO enrollment wait: on a fresh
    /// install the regular 10s attestation grace would block the paywall,
    /// and the quarantine path answers unattested calls fine.
    private func fetchPaywall(_ payload: PaywallRequestPayload) async -> PaywallResponsePayload? {
        guard let body = try? Payloads.encoder.encode(payload) else { return nil }
        let url = options.baseURL.appendingPathComponent("/api/sdk/v1/paywall")
        var headers = ["Content-Type": "application/json"]
        switch currentAttestation() {
        case .enrolled(let token):
            headers["Authorization"] = "Bearer \(token)"
        case .unattested(let reason):
            headers["X-RevenueHog-Unattested"] = reason.rawValue
        }
        let transport = self.transport
        let deadline = paywallTimeout
        let response = await withTaskGroup(of: TransportResponse?.self) { group in
            group.addTask { try? await transport.post(url: url, body: body, headers: headers) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let response, (200..<300).contains(response.status) else {
            if let response { log.warn("\(response.status) from /api/sdk/v1/paywall") }
            return nil
        }
        return try? JSONDecoder().decode(PaywallResponsePayload.self, from: response.body)
    }
}
