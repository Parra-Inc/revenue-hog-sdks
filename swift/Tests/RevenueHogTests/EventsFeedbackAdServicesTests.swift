import XCTest
@testable import RevenueHog

final class EventsFeedbackAdServicesTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func requests(_ t: MockTransport, _ path: String) -> [RecordedRequest] {
        t.recorded.filter { $0.url.path == path }
    }

    // MARK: - Events

    func testTrackBuffersUntilFlushThenSendsOneBatch() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.track("onboarding_step", properties: ["step": "welcome", "index": 0, "skipped": false])
        await client.track("paywall_viewed", properties: nil)
        XCTAssertTrue(requests(transport, "/api/sdk/v1/events").isEmpty)

        await client.flushAll()

        let sent = requests(transport, "/api/sdk/v1/events")
        XCTAssertEqual(sent.count, 1)
        let body = sent[0].json
        XCTAssertEqual(body["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(sent[0].headers["Authorization"], "Bearer dt_test_123")
        let events = body["events"] as? [[String: Any]] ?? []
        XCTAssertEqual(events.map { $0["name"] as? String }, ["onboarding_step", "paywall_viewed"])
        let props = events[0]["properties"] as? [String: Any]
        XCTAssertEqual(props?["step"] as? String, "welcome")
        XCTAssertEqual(props?["index"] as? Int, 0)
        XCTAssertEqual(props?["skipped"] as? Bool, false)
        XCTAssertTrue((events[0]["appUserId"] as? String)?.hasPrefix("$anon_") == true)
        XCTAssertNotNil(events[0]["at"] as? Int)
    }

    func testTrackDropsInvalidNames() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        for bad in ["", "Signup", "1st", "rh_internal", "has-dash", String(repeating: "a", count: 49)] {
            await client.track(bad, properties: nil)
        }
        await client.flushAll()

        XCTAssertTrue(requests(transport, "/api/sdk/v1/events").isEmpty)
    }

    func testTwentyEventsSendAutomaticallyAndBatchesCapAtFifty() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        for _ in 0..<20 { await client.track("tap", properties: nil) }
        XCTAssertEqual(requests(transport, "/api/sdk/v1/events").count, 1)

        let store = MemoryStore()
        let t2 = MockTransport()
        let c2 = TestSupport.makeClient(transport: t2, store: store, queueDirectory: TestSupport.tempDirectory())
        // Pre-fill 120 buffered events (e.g. from a previous offline session).
        let storage = Storage(store: store, secure: MemoryStore())
        storage.eventBuffer = (0..<120).map {
            BufferedEvent(name: "tap", properties: nil, at: Int64($0), appUserId: "u")
        }
        await c2.flushAll()
        let sizes = requests(t2, "/api/sdk/v1/events").map { ($0.json["events"] as? [Any])?.count }
        XCTAssertEqual(sizes, [50, 50, 20])
    }

    func testOfflineEventBatchIsQueuedAndReplayed() async {
        let transport = MockTransport(script: [.networkError, .networkError, .networkError])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        await client.track("tap", properties: nil)
        await client.flushEvents()
        XCTAssertEqual(DiskQueue(directory: directory).load().map(\.path), ["/api/sdk/v1/events"])

        await client.flushAll()
        XCTAssertTrue(DiskQueue(directory: directory).load().isEmpty)
        XCTAssertEqual(requests(transport, "/api/sdk/v1/events").count, 4)
    }

    func testEventTimerFlushes() async throws {
        let transport = MockTransport()
        let client = TestSupport.makeClient(
            transport: transport, queueDirectory: directory, eventFlushDelay: 0.05
        )
        await client.track("tap", properties: nil)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(requests(transport, "/api/sdk/v1/events").count, 1)
    }

    // MARK: - Feedback

    func testFeedbackSendsFullPayloadAndReturnsId() async {
        let transport = MockTransport(script: [.json(200, #"{"ok":true,"id":"fb_1"}"#)])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)
        await client.identify(userId: "user_42")

        let result = await client.sendFeedback(
            kind: .bug, message: "  It crashed  ", rating: 2,
            data: ["screen": "settings"], metadata: ["build": 42]
        )

        // identify consumed the scripted answer, feedback got a plain 200.
        XCTAssertEqual(result, .sent(id: nil))
        let req = requests(transport, "/api/sdk/v1/feedback").first
        XCTAssertEqual(req?.headers["Authorization"], "Bearer dt_test_123")
        let body = req?.json ?? [:]
        XCTAssertEqual(body["kind"] as? String, "bug")
        XCTAssertEqual(body["message"] as? String, "It crashed")
        XCTAssertEqual(body["rating"] as? Int, 2)
        XCTAssertEqual(body["appUserId"] as? String, "user_42")
        XCTAssertEqual(body["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual((body["data"] as? [String: Any])?["screen"] as? String, "settings")
        let meta = body["metadata"] as? [String: Any]
        XCTAssertEqual(meta?["osVersion"] as? String, "17.0.0")
        XCTAssertEqual(meta?["appVersion"] as? String, "2.1.0")
        XCTAssertEqual(meta?["build"] as? Int, 42)
    }

    func testFeedbackParsesServerId() async {
        let transport = MockTransport(script: [.json(200, #"{"ok":true,"id":"fb_9"}"#)])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)
        let result = await client.sendFeedback(kind: .idea, message: "Dark mode", rating: nil, data: nil, metadata: nil)
        XCTAssertEqual(result, .sent(id: "fb_9"))
    }

    func testFeedbackValidationRejectsLocally() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        let empty = await client.sendFeedback(kind: .bug, message: "   ", rating: nil, data: nil, metadata: nil)
        let rating = await client.sendFeedback(kind: .bug, message: "x", rating: 6, data: nil, metadata: nil)
        let long = await client.sendFeedback(
            kind: .bug, message: String(repeating: "a", count: 5_001), rating: nil, data: nil, metadata: nil
        )

        XCTAssertEqual(empty, .rejected(reason: "message is required"))
        XCTAssertEqual(rating, .rejected(reason: "rating must be an integer from 1 to 5"))
        if case .rejected = long {} else { XCTFail("expected rejected") }
        XCTAssertTrue(transport.recorded.isEmpty)
    }

    func testOfflineFeedbackIsQueuedThenDelivered() async {
        let transport = MockTransport(script: [.networkError, .status(503), .networkError])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)

        let result = await client.sendFeedback(kind: .question, message: "How?", rating: nil, data: nil, metadata: nil)
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(DiskQueue(directory: directory).load().map(\.path), ["/api/sdk/v1/feedback"])

        await client.flushAll()
        XCTAssertTrue(DiskQueue(directory: directory).load().isEmpty)
        XCTAssertEqual(requests(transport, "/api/sdk/v1/feedback").count, 4)
    }

    func testFeedbackServerRejectionIsNotQueued() async {
        let transport = MockTransport(script: [.status(400)])
        let client = TestSupport.makeClient(transport: transport, queueDirectory: directory)
        let result = await client.sendFeedback(kind: .praise, message: "Love it", rating: 5, data: nil, metadata: nil)
        XCTAssertEqual(result, .rejected(reason: "HTTP 400"))
        XCTAssertTrue(DiskQueue(directory: directory).load().isEmpty)
    }

    // MARK: - AdServices

    func testAdServicesTokenSentOncePerInstall() async {
        let store = MemoryStore()
        let secure = TestSupport.enrolledSecureStore()
        let transport = MockTransport()
        let client = TestSupport.makeClient(
            transport: transport, store: store, secureStore: secure, queueDirectory: directory,
            adServicesToken: { "tok_abc" }, storefront: { "USA" }
        )

        await client.start()
        await client.start()
        let again = TestSupport.makeClient(
            transport: transport, store: store, secureStore: secure, queueDirectory: directory,
            adServicesToken: { "tok_abc" }
        )
        await again.start()

        let sent = requests(transport, "/api/sdk/v1/adservices")
        XCTAssertEqual(sent.count, 1)
        let body = sent.first?.json ?? [:]
        XCTAssertEqual(body["token"] as? String, "tok_abc")
        XCTAssertEqual(body["bundleId"] as? String, "com.example.app")
        XCTAssertEqual(body["installId"] as? String, secure.get("rh_install_id"))
        XCTAssertEqual(body["environment"] as? String, "debug")
        XCTAssertEqual(body["appVersion"] as? String, "2.1.0")
        XCTAssertEqual(body["storefront"] as? String, "USA")
        XCTAssertEqual(sent.first?.headers["Authorization"], "Bearer dt_test_123")
    }

    func testAdServicesRetriesNextLaunchWhenNoToken() async {
        let store = MemoryStore()
        let transport = MockTransport()
        let first = TestSupport.makeClient(transport: transport, store: store, queueDirectory: directory)
        await first.start()
        XCTAssertTrue(requests(transport, "/api/sdk/v1/adservices").isEmpty)

        let second = TestSupport.makeClient(
            transport: transport, store: store, queueDirectory: directory, adServicesToken: { "tok" }
        )
        await second.start()
        XCTAssertEqual(requests(transport, "/api/sdk/v1/adservices").count, 1)
    }

    func testAdServicesDisabledByOption() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(
            transport: transport, queueDirectory: directory,
            options: Options(
                baseURL: URL(string: "https://example.test")!, logLevel: .silent,
                enableAdServicesAttribution: false
            ),
            adServicesToken: { "tok" }
        )
        await client.start()
        XCTAssertTrue(requests(transport, "/api/sdk/v1/adservices").isEmpty)
    }

    func testOfflineAdServicesIsQueued() async {
        let transport = MockTransport(script: [
            .status(200), // open
            .networkError, .networkError, .networkError,
        ])
        let client = TestSupport.makeClient(
            transport: transport, queueDirectory: directory, adServicesToken: { "tok" }
        )
        await client.start()
        XCTAssertEqual(DiskQueue(directory: directory).load().map(\.path), ["/api/sdk/v1/adservices"])
    }

    func testPropertyValueRoundTrips() throws {
        let values: [String: PropertyValue] = ["s": "a", "i": 3, "d": 1.5, "b": true]
        let data = try JSONEncoder().encode(values)
        XCTAssertEqual(try JSONDecoder().decode([String: PropertyValue].self, from: data), values)
    }
}
