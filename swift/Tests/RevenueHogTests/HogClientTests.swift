import XCTest
@testable import RevenueHog

final class HogClientTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testIdentifySendsBearerAuthAndFullPayload() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.identify(userId: "user_42")

        let request = transport.recorded.first
        XCTAssertEqual(request?.url.absoluteString, "https://example.test/api/sdk/v1/identify")
        XCTAssertEqual(request?.headers["Authorization"], "Bearer pk_test_123")
        XCTAssertEqual(request?.headers["Content-Type"], "application/json")
        XCTAssertEqual(request?.json["appUserId"] as? String, "user_42")
        XCTAssertEqual(request?.json["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(request?.json["platform"] as? String, "ios")
    }

    func testAttributeBeforeIdentifyUsesPersistedAnonymousId() async {
        let store = MemoryStore()
        let transport = MockTransport()
        let client = TestSupport.makeClient(
            transport: transport, store: store, queueDirectory: directory
        )

        await client.attribute(originalTransactionId: "txn_1", productId: "pro.monthly")

        let request = transport.recorded.first
        XCTAssertEqual(request?.url.path, "/api/sdk/v1/attribute")
        let anonId = try? XCTUnwrap(request?.json["appUserId"] as? String)
        XCTAssertTrue(anonId?.hasPrefix("$anon_") == true)
        // same anon id on a "second launch" with the same store
        let secondClient = TestSupport.makeClient(
            transport: transport, store: store, queueDirectory: directory
        )
        let laterId = await secondClient.appUserId
        XCTAssertEqual(anonId, laterId)
    }

    func testIdentifyReattributesTransactionsReportedAnonymously() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.attribute(originalTransactionId: "txn_1", productId: "pro.monthly")
        await client.identify(userId: "user_42")

        let attributeBodies = transport.recorded
            .filter { $0.url.path == "/api/sdk/v1/attribute" }
            .map { $0.json["appUserId"] as? String }
        XCTAssertEqual(attributeBodies.count, 2)
        XCTAssertTrue(attributeBodies[0]?.hasPrefix("$anon_") == true)
        XCTAssertEqual(attributeBodies[1], "user_42")
    }

    func testDuplicateAttributionForSameUserIsSkipped() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.attribute(originalTransactionId: "txn_1", productId: "p")
        await client.attribute(originalTransactionId: "txn_1", productId: "p")

        XCTAssertEqual(transport.recorded.count, 1)
    }

    func testRateLimitedRequestIsQueuedThenFlushed() async {
        // three 429s exhaust the retry budget → request goes to disk queue
        let transport = MockTransport(script: [.status(429), .status(429), .status(429)])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.setAttributes(["plan": "pro"])
        XCTAssertEqual(DiskQueue(directory: directory).load().count, 1)

        // network recovers (script empty → 200s) — flush drains the queue
        await client.flush()
        XCTAssertEqual(DiskQueue(directory: directory).load().count, 0)
        XCTAssertEqual(transport.recorded.count, 4)
        XCTAssertEqual(transport.recorded.last?.json["attributes"] as? [String: String], ["plan": "pro"])
    }

    func testNetworkErrorIsRetriedThenQueued() async {
        let transport = MockTransport(script: [.networkError, .networkError, .networkError])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.setAttributes(["a": "b"])

        XCTAssertEqual(transport.recorded.count, 3) // retried up to max
        XCTAssertEqual(DiskQueue(directory: directory).load().count, 1)
    }

    func testUnauthorizedIsDroppedNotQueued() async {
        let transport = MockTransport(script: [.status(401)])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.setAttributes(["a": "b"])

        XCTAssertEqual(transport.recorded.count, 1) // no retries on 401
        XCTAssertEqual(DiskQueue(directory: directory).load().count, 0)
    }

    func testResetIssuesFreshAnonymousIdAndClearsState() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.identify(userId: "user_42")
        let before = await client.appUserId
        await client.reset()
        let after = await client.appUserId

        XCTAssertEqual(before, "user_42")
        XCTAssertTrue(after.hasPrefix("$anon_"))
        XCTAssertNotEqual(before, after)
    }
}
