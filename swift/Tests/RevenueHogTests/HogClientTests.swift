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
        XCTAssertEqual(request?.headers["Authorization"], "Bearer dt_test_123")
        XCTAssertNil(request?.headers["X-RevenueHog-Unattested"])
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

        // network recovers (script empty → 200s); flush drains the queue
        await client.flush()
        XCTAssertEqual(DiskQueue(directory: directory).load().count, 0)
        XCTAssertEqual(transport.recorded.count, 4)
        XCTAssertEqual(transport.recorded.last?.json["attributes"] as? [String: String], ["plan": "pro"])
    }

    func testARequestQueuedDuringAFlushSurvivesIt() async {
        let queue = DiskQueue(directory: directory)
        queue.append(PendingRequest(path: "/api/sdk/v1/identify", body: Data("{}".utf8)))
        let transport = HookTransport()
        let directory = self.directory!
        transport.onPost = { request in
            // Something failed and was queued while this delivery was out.
            if request.url.path == "/api/sdk/v1/identify" {
                DiskQueue(directory: directory)
                    .append(PendingRequest(path: "/api/sdk/v1/attribute", body: Data("{}".utf8)))
            }
        }
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.flush()

        XCTAssertEqual(transport.recorded.map(\.url.path), ["/api/sdk/v1/identify", "/api/sdk/v1/attribute"])
        XCTAssertEqual(queue.load().count, 0)
    }

    func testAFlushAskedForDuringAFlushWaitsAndDeliversNothingTwice() async {
        DiskQueue(directory: directory)
            .append(PendingRequest(path: "/api/sdk/v1/identify", body: Data("{}".utf8)))
        let transport = HookTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)
        let nested = TaskBox()
        // Started while the first flush still has the item out, and not waited
        // on there: it waits for that flush, which is waiting on this hook. The
        // hook holds the item out long enough for a flush that did not wait to
        // deliver it a second time.
        transport.onPost = { [unowned transport] _ in
            guard transport.recorded.count == 1 else { return }
            nested.task = Task { await client.flush() }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        await client.flush()
        await nested.task?.value

        XCTAssertEqual(transport.recorded.count, 1)
    }

    /// The order identify depends on: a stale attribution still queued is
    /// delivered before the re-attribution, so the user's lands last and the
    /// server's upsert leaves the purchase with them.
    func testIdentifyDuringAFlushLandsItsReattributionLast() async throws {
        let store = MemoryStore()
        store.set("$anon_x", forKey: "rh_anonymous_id")
        store.set(#"{"txn_1":"$anon_x"}"#, forKey: "rh_sent_txns")
        let stale = try Payloads.encoder.encode(AttributePayload(
            appUserId: "$anon_x", bundleId: "com.example.app", originalTransactionId: "txn_1"
        ))
        DiskQueue(directory: directory).append(PendingRequest(path: "/api/sdk/v1/attribute", body: stale))
        let gate = Gate()
        let landed = Landings()
        let transport = HookTransport()
        transport.onPost = { request in
            guard request.url.path == "/api/sdk/v1/attribute" else { return }
            let user = request.json["appUserId"] as? String ?? ""
            if user == "$anon_x" { await gate.wait() }
            // What the server's upsert sees last is what it keeps: the order
            // the requests finish in, not the order they start in.
            landed.append(user)
        }
        let client = TestSupport.makeClient(transport: transport, store: store, queueDirectory: directory)

        let draining = Task { await client.flush() }
        while transport.recorded.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        let identifying = Task { await client.identify(userId: "u1") }
        // Long enough for identify to post and, without the wait, to
        // re-attribute while the stale one is still out.
        try await Task.sleep(nanoseconds: 300_000_000)
        gate.open()
        await draining.value
        await identifying.value

        XCTAssertEqual(landed.users, ["$anon_x", "u1"])
    }

    /// A queue the disk will not let it rewrite: each item would otherwise be
    /// sent again and again until the server refused.
    func testAFlushStopsWhenTheQueueCannotBeRewritten() async throws {
        let queue = DiskQueue(directory: directory)
        queue.append(PendingRequest(path: "/api/sdk/v1/identify", body: Data("1".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: directory.path), "root writes anyway")
        // A second delivery is refused, so a loop shows as two requests rather than a hang.
        let transport = MockTransport(script: [.status(200), .status(503)])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.flush()

        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertEqual(queue.load().count, 1)
    }

    /// A drain that stopped early left the anonymous attribution queued, and
    /// identify has since sent the transaction for the user. Replayed as it
    /// was, it would land last and hand the purchase back to the anonymous id.
    func testAQueuedAttributionGoesOutUnderItsTransactionsOwner() async throws {
        let store = MemoryStore()
        store.set(#"{"txn_1":"u1"}"#, forKey: "rh_sent_txns")
        let stale = try Payloads.encoder.encode(AttributePayload(
            appUserId: "$anon_x", bundleId: "com.example.app", originalTransactionId: "txn_1",
            productId: "pro.monthly", jws: "eyJ.signed.jws"
        ))
        DiskQueue(directory: directory).append(PendingRequest(path: HogClient.attributePath, body: stale))
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, store: store, queueDirectory: directory)

        await client.flush()

        let sent = transport.recorded.first?.json
        XCTAssertEqual(sent?["appUserId"] as? String, "u1")
        XCTAssertEqual(sent?["jws"] as? String, "eyJ.signed.jws")
        XCTAssertEqual(sent?["productId"] as? String, "pro.monthly")
        XCTAssertTrue(DiskQueue(directory: directory).load().isEmpty)
    }

    /// After a reset nothing says who the transaction belongs to now, so a
    /// queued attribution keeps the user it was made for, like everything else.
    func testAQueuedAttributionKeepsItsUserWhenNothingNewerIsKnown() async throws {
        let stale = try Payloads.encoder.encode(AttributePayload(
            appUserId: "user_old", bundleId: "com.example.app", originalTransactionId: "txn_1"
        ))
        DiskQueue(directory: directory).append(PendingRequest(path: HogClient.attributePath, body: stale))
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.flush()

        XCTAssertEqual(transport.recorded.first?.body, stale)
    }

    func testNetworkErrorIsRetriedThenQueued() async {
        let transport = MockTransport(script: [.networkError, .networkError, .networkError])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.setAttributes(["a": "b"])

        XCTAssertEqual(transport.recorded.count, 3) // retried up to max
        XCTAssertEqual(DiskQueue(directory: directory).load().count, 1)
    }

    func testAttributeSendsJwsWhenProvided() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.attribute(
            originalTransactionId: "txn_1", productId: "pro.monthly", jws: "eyJhbGciOi.fake.sig"
        )

        let request = transport.recorded.first
        XCTAssertEqual(request?.url.path, "/api/sdk/v1/attribute")
        XCTAssertEqual(request?.json["jws"] as? String, "eyJhbGciOi.fake.sig")
        XCTAssertEqual(request?.json["originalTransactionId"] as? String, "txn_1")
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

/// The users attributions landed for, in the order they finished.
private final class Landings: @unchecked Sendable {
    private let lock = NSLock()
    private var landed: [String] = []

    var users: [String] {
        lock.lock(); defer { lock.unlock() }
        return landed
    }

    func append(_ user: String) {
        lock.lock(); landed.append(user); lock.unlock()
    }
}
