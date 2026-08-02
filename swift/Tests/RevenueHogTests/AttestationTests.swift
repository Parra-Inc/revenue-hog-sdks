import XCTest
import CryptoKit
@testable import RevenueHog

/// Enrollment state machine, driven end to end through `HogClient` with a
/// fake AttestService and a scripted transport. `"aGVsbG8"` is base64url
/// for "hello".
final class AttestationTests: XCTestCase {
    private var directory: URL!

    private let challengeResponse = #"{"challenge":"aGVsbG8"}"#

    private func tokenResponse(_ token: String = "dt_new") -> String {
        #"{"deviceToken":"\#(token)"}"#
    }

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Happy path

    func testEnrollsThenSendsAuthorizedRequest() async {
        let transport = MockTransport(script: [
            .json(200, challengeResponse),
            .json(200, tokenResponse("dt_abc")),
        ])
        let secureStore = MemoryStore()
        let service = FakeAttestService()
        let client = TestSupport.makeClient(
            transport: transport, secureStore: secureStore,
            attestService: service, queueDirectory: directory
        )

        await client.identify(userId: "user_42")

        let paths = transport.recorded.map(\.url.path)
        XCTAssertEqual(paths, [
            "/api/sdk/v1/attest/challenge",
            "/api/sdk/v1/attest",
            "/api/sdk/v1/identify",
        ])
        let attest = transport.recorded[1]
        XCTAssertEqual(attest.json["keyId"] as? String, "key_1")
        XCTAssertEqual(attest.json["challenge"] as? String, "aGVsbG8")
        XCTAssertEqual(
            attest.json["attestation"] as? String,
            Data("fake-attestation".utf8).base64EncodedString()
        )
        XCTAssertEqual(attest.json["bundleId"] as? String, "com.example.app")
        let identify = transport.recorded[2]
        XCTAssertEqual(identify.headers["Authorization"], "Bearer dt_abc")
        XCTAssertNil(identify.headers["X-RevenueHog-Unattested"])
        XCTAssertEqual(secureStore.get("rh_device_token"), "dt_abc")
    }

    func testStoredTokenSkipsEnrollmentEntirely() async {
        let transport = MockTransport()
        let service = FakeAttestService()
        let client = TestSupport.makeClient(
            transport: transport, attestService: service, queueDirectory: directory
        )

        await client.identify(userId: "user_42")

        XCTAssertEqual(transport.recorded.map(\.url.path), ["/api/sdk/v1/identify"])
        XCTAssertEqual(service.generateKeyCalls, 0)
        XCTAssertTrue(service.attestKeyCalls.isEmpty)
    }

    func testClientDataHashIsSha256OfDecodedChallenge() async {
        let transport = MockTransport(script: [
            .json(200, challengeResponse),
            .json(200, tokenResponse()),
        ])
        let service = FakeAttestService()
        let client = TestSupport.makeClient(
            transport: transport, secureStore: MemoryStore(),
            attestService: service, queueDirectory: directory
        )

        await client.identify(userId: "u")

        let expected = Data(SHA256.hash(data: Data("hello".utf8)))
        XCTAssertEqual(service.attestKeyCalls.first?.clientDataHash, expected)
    }

    // MARK: - Unattested sessions

    func testUnsupportedDeviceSendsUnsupportedHeader() async {
        let transport = MockTransport()
        let service = FakeAttestService()
        service.supported = false
        let client = TestSupport.makeClient(
            transport: transport, secureStore: MemoryStore(),
            attestService: service, queueDirectory: directory
        )

        await client.identify(userId: "u")

        let request = transport.recorded.first
        XCTAssertEqual(transport.recorded.count, 1)
        XCTAssertNil(request?.headers["Authorization"])
        XCTAssertEqual(request?.headers["X-RevenueHog-Unattested"], "unsupported")
        XCTAssertEqual(service.generateKeyCalls, 0)
    }

    func testSimulatorSendsSimulatorHeader() async {
        let transport = MockTransport()
        let client = TestSupport.makeClient(
            transport: transport, secureStore: MemoryStore(),
            queueDirectory: directory, isSimulator: true
        )

        await client.identify(userId: "u")

        let request = transport.recorded.first
        XCTAssertNil(request?.headers["Authorization"])
        XCTAssertEqual(request?.headers["X-RevenueHog-Unattested"], "simulator")
    }

    func testSlowEnrollmentGoesOutPending() async {
        let transport = MockTransport(script: [.json(200, challengeResponse)])
        let service = FakeAttestService()
        service.hangs = true
        let client = TestSupport.makeClient(
            transport: transport, secureStore: MemoryStore(),
            attestService: service, queueDirectory: directory,
            enrollmentWait: 0.05
        )

        await client.identify(userId: "u")

        let identify = transport.recorded.first { $0.url.path == "/api/sdk/v1/identify" }
        XCTAssertNil(identify?.headers["Authorization"])
        XCTAssertEqual(identify?.headers["X-RevenueHog-Unattested"], "pending")
    }

    // MARK: - Apple service errors

    func testServerUnavailableRetriesWithSameKeyThenSucceeds() async {
        let transport = MockTransport(script: [
            .json(200, challengeResponse),
            .json(200, challengeResponse),
            .json(200, challengeResponse),
            .json(200, tokenResponse("dt_ok")),
        ])
        let service = FakeAttestService()
        service.attestKeyResults = [
            .failure(AttestServiceError.serverUnavailable),
            .failure(AttestServiceError.serverUnavailable),
        ]
        let client = TestSupport.makeClient(
            transport: transport, secureStore: MemoryStore(),
            attestService: service, queueDirectory: directory
        )

        await client.identify(userId: "u")

        XCTAssertEqual(service.generateKeyCalls, 1)
        XCTAssertEqual(service.attestKeyCalls.map(\.keyId), ["key_1", "key_1", "key_1"])
        let identify = transport.recorded.last
        XCTAssertEqual(identify?.headers["Authorization"], "Bearer dt_ok")
    }

    func testServerUnavailableExhaustionGoesUnattestedKeepingKey() async {
        let transport = MockTransport(script: [
            .json(200, challengeResponse),
            .json(200, challengeResponse),
            .json(200, challengeResponse),
        ])
        let secureStore = MemoryStore()
        let service = FakeAttestService()
        service.attestKeyResults = [
            .failure(AttestServiceError.serverUnavailable),
            .failure(AttestServiceError.serverUnavailable),
            .failure(AttestServiceError.serverUnavailable),
        ]
        let client = TestSupport.makeClient(
            transport: transport, secureStore: secureStore,
            attestService: service, queueDirectory: directory
        )

        await client.identify(userId: "u")

        let identify = transport.recorded.last
        XCTAssertEqual(identify?.headers["X-RevenueHog-Unattested"], "enroll-failed")
        // the key survives for next launch, per Apple guidance
        XCTAssertEqual(secureStore.get("rh_attest_key_id"), "key_1")
    }

    func testInvalidKeyRegeneratesOnce() async {
        let transport = MockTransport(script: [
            .json(200, challengeResponse),
            .json(200, challengeResponse),
            .json(200, tokenResponse("dt_ok")),
        ])
        let secureStore = MemoryStore()
        let service = FakeAttestService()
        service.attestKeyResults = [.failure(AttestServiceError.invalidKey)]
        let client = TestSupport.makeClient(
            transport: transport, secureStore: secureStore,
            attestService: service, queueDirectory: directory
        )

        await client.identify(userId: "u")

        XCTAssertEqual(service.generateKeyCalls, 2)
        XCTAssertEqual(service.attestKeyCalls.map(\.keyId), ["key_1", "key_2"])
        XCTAssertEqual(secureStore.get("rh_attest_key_id"), "key_2")
        XCTAssertEqual(transport.recorded.last?.headers["Authorization"], "Bearer dt_ok")
    }

    func testSecondInvalidKeyGivesUpForTheSession() async {
        let transport = MockTransport(script: [
            .json(200, challengeResponse),
            .json(200, challengeResponse),
        ])
        let service = FakeAttestService()
        service.attestKeyResults = [
            .failure(AttestServiceError.invalidKey),
            .failure(AttestServiceError.invalidKey),
        ]
        let client = TestSupport.makeClient(
            transport: transport, secureStore: MemoryStore(),
            attestService: service, queueDirectory: directory
        )

        await client.identify(userId: "u")

        XCTAssertEqual(service.generateKeyCalls, 2)
        let identify = transport.recorded.last
        XCTAssertEqual(identify?.headers["X-RevenueHog-Unattested"], "enroll-failed")
    }

    // MARK: - Server rejections

    func testServer404BacksOffForTwentyFourHours() async {
        let clock = TestClock()
        let store = MemoryStore()
        let secureStore = MemoryStore()
        let transport = MockTransport(script: [
            .json(200, challengeResponse),
            .status(404),
        ])
        let client = TestSupport.makeClient(
            transport: transport, store: store, secureStore: secureStore,
            queueDirectory: directory, now: { clock.now }
        )

        await client.identify(userId: "u")
        XCTAssertEqual(
            transport.recorded.last?.headers["X-RevenueHog-Unattested"], "enroll-failed"
        )
        let challengeCount = transport.recorded
            .filter { $0.url.path == "/api/sdk/v1/attest/challenge" }.count
        XCTAssertEqual(challengeCount, 1)

        // "next launch" one hour later: still inside the backoff window,
        // so no new challenge is fetched
        clock.advance(by: 3600)
        let second = TestSupport.makeClient(
            transport: transport, store: store, secureStore: secureStore,
            queueDirectory: directory, now: { clock.now }
        )
        await second.setAttributes(["a": "b"])
        let challengesAfterBackoff = transport.recorded
            .filter { $0.url.path == "/api/sdk/v1/attest/challenge" }.count
        XCTAssertEqual(challengesAfterBackoff, 1)

        // 25 hours later the window has passed and enrollment retries
        clock.advance(by: 25 * 3600)
        let third = TestSupport.makeClient(
            transport: transport, store: store, secureStore: secureStore,
            queueDirectory: directory, now: { clock.now }
        )
        await third.setAttributes(["a": "b"])
        let challengesAfterExpiry = transport.recorded
            .filter { $0.url.path == "/api/sdk/v1/attest/challenge" }.count
        XCTAssertEqual(challengesAfterExpiry, 2)
    }

    // MARK: - 401 handling

    func testUnauthorizedClearsTokenAndReenrollsOnce() async {
        let secureStore = TestSupport.enrolledSecureStore(token: "dt_old")
        let transport = MockTransport(script: [
            .status(401),
            .json(200, challengeResponse),
            .json(200, tokenResponse("dt_new")),
        ])
        let client = TestSupport.makeClient(
            transport: transport, secureStore: secureStore, queueDirectory: directory
        )

        await client.identify(userId: "u")

        let paths = transport.recorded.map(\.url.path)
        XCTAssertEqual(paths, [
            "/api/sdk/v1/identify",
            "/api/sdk/v1/attest/challenge",
            "/api/sdk/v1/attest",
            "/api/sdk/v1/identify",
        ])
        XCTAssertEqual(transport.recorded[0].headers["Authorization"], "Bearer dt_old")
        XCTAssertEqual(transport.recorded[3].headers["Authorization"], "Bearer dt_new")
        XCTAssertEqual(secureStore.get("rh_device_token"), "dt_new")
    }

    func testSecondUnauthorizedGoesUnattestedForTheSession() async {
        let secureStore = TestSupport.enrolledSecureStore(token: "dt_old")
        let transport = MockTransport(script: [
            .status(401),
            .json(200, challengeResponse),
            .json(200, tokenResponse("dt_new")),
            .status(401),
        ])
        let client = TestSupport.makeClient(
            transport: transport, secureStore: secureStore, queueDirectory: directory
        )

        await client.identify(userId: "u")

        let final = transport.recorded.last
        XCTAssertEqual(final?.url.path, "/api/sdk/v1/identify")
        XCTAssertNil(final?.headers["Authorization"])
        XCTAssertEqual(final?.headers["X-RevenueHog-Unattested"], "enroll-failed")
        XCTAssertNil(secureStore.get("rh_device_token"))

        // later calls in the same session stay unattested, no more enrolling
        let challengeCount = transport.recorded
            .filter { $0.url.path == "/api/sdk/v1/attest/challenge" }.count
        await client.setAttributes(["a": "b"])
        let after = transport.recorded
            .filter { $0.url.path == "/api/sdk/v1/attest/challenge" }.count
        XCTAssertEqual(challengeCount, after)
    }

    func testUnauthorizedWhileUnattestedIsDroppedNotQueued() async {
        let service = FakeAttestService()
        service.supported = false
        let transport = MockTransport(script: [.status(401)])
        let client = TestSupport.makeClient(
            transport: transport, secureStore: MemoryStore(),
            attestService: service, queueDirectory: directory
        )

        await client.setAttributes(["a": "b"])

        XCTAssertEqual(transport.recorded.count, 1) // no retries on 401
        XCTAssertEqual(DiskQueue(directory: directory).load().count, 0)
    }
}

/// Adjustable clock for the 24h backoff window.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
