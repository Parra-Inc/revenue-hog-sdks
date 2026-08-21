import XCTest
@testable import RevenueHog

final class PaywallTests: XCTestCase {
    private let experimentJSON = """
    {"entitlement":"pro","skus":[{"productId":"pro_annual","kind":"subscription"},\
    {"productId":"pro_monthly","kind":"subscription"},{"productId":"credits_500","kind":"iap"}],\
    "experimentId":"exp_1","variantKey":"b","ttlSeconds":900}
    """

    private func paywallRequests(_ transport: MockTransport) -> [RecordedRequest] {
        transport.recorded.filter { $0.url.path == "/api/sdk/v1/paywall" }
    }

    func testFetchSendsInstallIdAndDecodesOrderedSkus() async {
        let transport = MockTransport(script: [.json(200, experimentJSON)])
        let client = TestSupport.makeClient(transport: transport)

        let paywall = await client.paywall(entitlement: "pro", fallback: ["fb_monthly"])

        XCTAssertEqual(paywall.productIds, ["pro_annual", "pro_monthly", "credits_500"])
        XCTAssertEqual(paywall.skus.map(\.kind), [.subscription, .subscription, .iap])
        XCTAssertEqual(paywall.experimentId, "exp_1")
        XCTAssertEqual(paywall.variantKey, "b")
        XCTAssertFalse(paywall.isFallback)

        let request = paywallRequests(transport).first
        XCTAssertEqual(request?.json["entitlement"] as? String, "pro")
        XCTAssertEqual(request?.json["bundleId"] as? String, "com.example.app")
        let installId = request?.json["installId"] as? String
        XCTAssertEqual(installId?.isEmpty, false)
        let anonId = request?.json["appUserId"] as? String
        XCTAssertTrue(anonId?.hasPrefix("$anon_") == true)
    }

    func testInstallIdPersistsAcrossClientsAndSurvivesReset() async {
        let secure = TestSupport.enrolledSecureStore()
        let transport = MockTransport(script: [.json(200, experimentJSON), .json(200, experimentJSON)])
        let first = TestSupport.makeClient(transport: transport, secureStore: secure)
        _ = await first.paywall(entitlement: "pro", fallback: [])
        await first.reset()

        let second = TestSupport.makeClient(transport: transport, secureStore: secure)
        _ = await second.paywall(entitlement: "pro", fallback: [])

        let ids = paywallRequests(transport).compactMap { $0.json["installId"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
    }

    func testFreshCacheSkipsTheNetwork() async {
        let transport = MockTransport(script: [.json(200, experimentJSON)])
        let client = TestSupport.makeClient(transport: transport)

        let first = await client.paywall(entitlement: "pro", fallback: [])
        let second = await client.paywall(entitlement: "pro", fallback: [])

        XCTAssertEqual(first, second)
        XCTAssertEqual(paywallRequests(transport).count, 1)
    }

    func testEmptyAnswerServesTheCompiledFallback() async {
        let transport = MockTransport(
            script: [.json(200, #"{"entitlement":"pro","skus":[],"ttlSeconds":3600}"#)]
        )
        let client = TestSupport.makeClient(transport: transport)

        let paywall = await client.paywall(entitlement: "pro", fallback: ["fb_monthly", "fb_annual"])

        XCTAssertTrue(paywall.isFallback)
        XCTAssertEqual(paywall.productIds, ["fb_monthly", "fb_annual"])
        XCTAssertEqual(paywall.skus.map(\.kind), [.unknown, .unknown])
        XCTAssertNil(paywall.experimentId)
    }

    func testNetworkFailureServesStaleCacheHoweverOld() async {
        let store = MemoryStore()
        let transport = MockTransport(script: [.networkError])
        let client = TestSupport.makeClient(transport: transport, store: store)
        let user = await client.appUserId

        // A cache entry far past its TTL: stale beats the fallback on error.
        let storage = Storage(store: store, secure: MemoryStore())
        storage.paywallCache = [
            "pro": CachedPaywall(
                entitlement: "pro",
                productIds: ["cached_annual"],
                kinds: ["subscription"],
                experimentId: "exp_1",
                variantKey: "b",
                ttlSeconds: 60,
                fetchedAt: Date(timeIntervalSinceNow: -7200),
                appUserId: user
            )
        ]

        let paywall = await client.paywall(entitlement: "pro", fallback: ["fb"])

        XCTAssertEqual(paywall.productIds, ["cached_annual"])
        XCTAssertEqual(paywall.variantKey, "b")
        XCTAssertFalse(paywall.isFallback)
    }

    func testNetworkFailureWithoutCacheServesTheFallback() async {
        let transport = MockTransport(script: [.networkError])
        let client = TestSupport.makeClient(transport: transport)

        let paywall = await client.paywall(entitlement: "pro", fallback: ["fb_monthly"])

        XCTAssertTrue(paywall.isFallback)
        XCTAssertEqual(paywall.productIds, ["fb_monthly"])
    }

    func testIdentityChangeInvalidatesTheCache() async {
        let transport = MockTransport(script: [
            .json(200, experimentJSON), .status(200), .json(200, experimentJSON),
        ])
        let client = TestSupport.makeClient(transport: transport)

        _ = await client.paywall(entitlement: "pro", fallback: [])
        await client.identify(userId: "user_42")
        _ = await client.paywall(entitlement: "pro", fallback: [])

        let requests = paywallRequests(transport)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.json["appUserId"] as? String, "user_42")
    }

    func testForceVariantBypassesAndNeverPoisonsTheCache() async {
        let forced = """
        {"entitlement":"pro","skus":[{"productId":"forced_sku","kind":"subscription"}],\
        "experimentId":"exp_1","variantKey":"c","forced":true,"ttlSeconds":900}
        """
        let transport = MockTransport(script: [.json(200, forced), .json(200, experimentJSON)])
        let client = TestSupport.makeClient(transport: transport)

        let preview = await client.paywall(entitlement: "pro", fallback: [], forceVariant: "c")
        let real = await client.paywall(entitlement: "pro", fallback: [])

        XCTAssertEqual(preview.productIds, ["forced_sku"])
        XCTAssertEqual(real.productIds, ["pro_annual", "pro_monthly", "credits_500"])
        XCTAssertEqual(paywallRequests(transport).count, 2)
        XCTAssertEqual(
            paywallRequests(transport).first?.json["forceVariant"] as? String, "c"
        )
        XCTAssertNil(paywallRequests(transport).last?.json["forceVariant"])
    }

    func testHangingNetworkFallsBackWithinTheDeadline() async {
        let transport = MockTransport(script: [.hang])
        let client = TestSupport.makeClient(transport: transport, paywallTimeout: 0.2)

        let started = Date()
        let paywall = await client.paywall(entitlement: "pro", fallback: ["fb"])

        XCTAssertTrue(paywall.isFallback)
        XCTAssertEqual(paywall.productIds, ["fb"])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testPaywallShownPostsTheImpressionOnlyUnderAnExperiment() async {
        let transport = MockTransport(script: [.json(200, experimentJSON), .status(200)])
        let client = TestSupport.makeClient(transport: transport)

        let paywall = await client.paywall(entitlement: "pro", fallback: [])
        await client.paywallShown(paywall, rendered: ["pro_annual", "pro_monthly"])

        let impressions = transport.recorded.filter {
            $0.url.path == "/api/sdk/v1/paywall/impression"
        }
        XCTAssertEqual(impressions.count, 1)
        XCTAssertEqual(impressions.first?.json["experimentId"] as? String, "exp_1")
        XCTAssertEqual(
            impressions.first?.json["renderedSkus"] as? [String],
            ["pro_annual", "pro_monthly"]
        )
        XCTAssertEqual(
            impressions.first?.json["installId"] as? String,
            paywallRequests(transport).first?.json["installId"] as? String
        )

        // Defaults (no experiment) never beacon.
        await client.paywallShown(
            .fallback(entitlement: "pro", productIds: ["fb"]), rendered: ["fb"]
        )
        XCTAssertEqual(
            transport.recorded.filter { $0.url.path == "/api/sdk/v1/paywall/impression" }.count,
            1
        )
    }

    func testUnknownKindDecodesAsUnknown() async {
        let future = """
        {"entitlement":"pro","skus":[{"productId":"x","kind":"bundle"}],"ttlSeconds":900}
        """
        let transport = MockTransport(script: [.json(200, future)])
        let client = TestSupport.makeClient(transport: transport)

        let paywall = await client.paywall(entitlement: "pro", fallback: [])

        XCTAssertEqual(paywall.skus.map(\.kind), [.unknown])
        XCTAssertFalse(paywall.isFallback)
    }
}
