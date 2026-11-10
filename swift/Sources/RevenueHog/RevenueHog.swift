import Foundation

/// RevenueHog user-level attribution.
///
/// One required line, in your `App` init or
/// `application(_:didFinishLaunchingWithOptions:)`:
///
/// ```swift
/// RevenueHog.configure()
/// ```
///
/// That's it. No API key: the SDK enrolls the device with App Attest and
/// the server maps the attested bundle id to your org. Purchases are
/// attributed automatically via StoreKit 2. Call `identify(userId:)` when
/// you know who the user is.
///
/// Note: RevenueHog's revenue tracking works entirely server-side without
/// this SDK. Installing it adds user-level attribution: knowing *which*
/// of your users a purchase belongs to.
public enum RevenueHog {
    private static let lock = NSLock()
    private static var client: HogClient?
    private static var listener: Task<Void, Never>?

    /// Sets up the SDK. Call once, as early as possible. Safe to call
    /// again (reconfigures); safe to never call (everything else no-ops).
    public static func configure(options: Options = Options()) {
        lock.lock()
        defer { lock.unlock() }
        listener?.cancel()
        let client = HogClient(options: options)
        self.client = client
        let log = Logger(level: options.logLevel)
        Task.detached(priority: .utility) { EntitlementCheck.run(log: log) }
        Task {
            await client.start()
            if options.enableChurnSurveyAutoTrigger {
                await autoChurnSurvey(client)
            }
        }
        #if canImport(StoreKit)
        if options.enableAutoAttribution {
            listener = TransactionObserver.start(client: client)
        }
        #endif
    }

    /// Tells RevenueHog who this user is. Anything reported before this
    /// call (under the persisted anonymous id) is re-attributed to `userId`.
    public static func identify(userId: String) {
        withClient { await $0.identify(userId: userId) }
    }

    /// Attaches flat string key/values to the current user's profile.
    public static func setAttributes(_ attributes: [String: String]) {
        withClient { await $0.setAttributes(attributes) }
    }

    /// Manually links a purchase to the current user. Only needed when
    /// `enableAutoAttribution` is off or purchases happen outside StoreKit 2.
    public static func attributePurchase(
        originalTransactionId: String, productId: String? = nil
    ) {
        withClient {
            await $0.attribute(
                originalTransactionId: originalTransactionId, productId: productId
            )
        }
    }

    /// Forgets the current user (call on logout). A fresh anonymous id is
    /// issued for whatever happens next.
    public static func reset() {
        withClient { await $0.reset() }
    }

    /// Which SKUs this install's paywall should offer for `entitlement`, as
    /// an ORDERED list the dashboard controls (and can A/B test) without an
    /// app update. Never throws and never blocks long: fresh cache, then a
    /// short network fetch, then stale cache, then your `fallback` list.
    ///
    /// `fallback` is required on purpose: the paywall is the money path,
    /// and the compiled-in list is what renders when RevenueHog cannot
    /// answer. Call this when the paywall is about to show, render the SKUs
    /// in the returned order (see `Paywall.products()`), and call
    /// `paywallShown(_:rendered:)` once it is on screen.
    ///
    /// `forceVariant` is for QA only: it previews a named variant, is
    /// honored by the server only for non-Production StoreKit environments,
    /// and records nothing.
    public static func paywall(
        for entitlement: String,
        fallback: [String],
        forceVariant: String? = nil
    ) async -> Paywall {
        lock.lock()
        let client = self.client
        lock.unlock()
        guard let client else {
            Logger(level: .warn).warn("not configured, call RevenueHog.configure() first")
            return .fallback(entitlement: entitlement, productIds: fallback)
        }
        return await client.paywall(
            entitlement: entitlement, fallback: fallback, forceVariant: forceVariant
        )
    }

    /// Reports that a paywall actually APPEARED, with the product ids that
    /// really rendered (after StoreKit loading). Fetching assigns;
    /// impressions expose: this is what keeps prefetched-but-never-shown
    /// paywalls out of experiment denominators, and what surfaces a variant
    /// whose SKU failed to load as a broken test instead of a losing offer.
    /// No-op when no experiment is running.
    public static func paywallShown(_ paywall: Paywall, rendered: [String]) {
        withClient { await $0.paywallShown(paywall, rendered: rendered) }
    }

    /// Shows the churn survey now, for apps with their own "Manage
    /// subscription" button: call it right before opening subscription
    /// management. Respects the dashboard switch, sampling and the
    /// once-per-90-days cap; returns `.notShown` when any of them says no.
    /// The answer (or the skip) is recorded automatically.
    @discardableResult
    public static func presentChurnSurvey(productId: String? = nil) async -> ChurnSurveyResult {
        lock.lock()
        let client = self.client
        lock.unlock()
        guard let client else {
            Logger(level: .warn).warn("not configured, call RevenueHog.configure() first")
            return .notShown
        }
        return await present(client, ignoreTrigger: true, productId: productId)
    }

    private static func present(
        _ client: HogClient, ignoreTrigger: Bool, productId: String?
    ) async -> ChurnSurveyResult {
        guard let survey = await client.churnSurvey(ignoreTrigger: ignoreTrigger) else { return .notShown }
        await client.churnSurveyShown()
        let result = await ChurnSurveyPresenter.present(survey)
        await client.submitChurnSurvey(survey, result: result, productId: productId)
        return result
    }

    /// First launch after auto-renew turned off: ask once per cancellation.
    private static func autoChurnSurvey(_ client: HogClient) async {
        guard let cancelled = await client.claimNewlyCancelledSubscription() else { return }
        // Give the host app a moment to put its first screen up.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let result = await present(client, ignoreTrigger: false, productId: cancelled.productId)
        if result != .notShown {
            await client.markSubscriptionHandled(cancelled.originalId)
        }
    }

    private static func withClient(_ work: @escaping @Sendable (HogClient) async -> Void) {
        lock.lock()
        let client = self.client
        lock.unlock()
        guard let client else {
            Logger(level: .warn).warn("not configured, call RevenueHog.configure() first")
            return
        }
        Task { await work(client) }
    }
}
