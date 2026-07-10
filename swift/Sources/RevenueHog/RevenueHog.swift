import Foundation

/// RevenueHog user-level attribution.
///
/// One required line, in your `App` init or
/// `application(_:didFinishLaunchingWithOptions:)`:
///
/// ```swift
/// RevenueHog.configure(apiKey: "pk_live_…")
/// ```
///
/// That's it. Purchases are attributed automatically via StoreKit 2.
/// Call `identify(userId:)` when you know who the user is.
///
/// Note: RevenueHog's revenue tracking works entirely server-side without
/// this SDK. Installing it adds user-level attribution — knowing *which*
/// of your users a purchase belongs to.
public enum RevenueHog {
    private static let lock = NSLock()
    private static var client: HogClient?
    private static var listener: Task<Void, Never>?

    /// Sets up the SDK. Call once, as early as possible. Safe to call
    /// again (reconfigures); safe to never call (everything else no-ops).
    public static func configure(apiKey: String, options: Options = Options()) {
        lock.lock()
        defer { lock.unlock() }
        listener?.cancel()
        let client = HogClient(apiKey: apiKey, options: options)
        self.client = client
        Task { await client.flush() }
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

    private static func withClient(_ work: @escaping @Sendable (HogClient) async -> Void) {
        lock.lock()
        let client = self.client
        lock.unlock()
        guard let client else {
            Logger(level: .warn).warn("not configured — call RevenueHog.configure(apiKey:) first")
            return
        }
        Task { await work(client) }
    }
}
