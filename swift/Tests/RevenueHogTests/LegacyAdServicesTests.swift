import XCTest
@testable import RevenueHog

/// Apps that hand-rolled AdServices reporting before adopting the SDK left a
/// "reported" Bool in their defaults. The SDK must not send the token again.
final class LegacyAdServicesTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func run(legacy: [String: Bool]) async -> (sent: Int, store: MemoryStore) {
        let store = MemoryStore()
        let transport = MockTransport()
        let client = TestSupport.makeClient(
            transport: transport, store: store, queueDirectory: directory,
            adServicesToken: { "tok" },
            legacyAdServicesFlag: { legacy[$0] ?? false }
        )
        await client.start()
        let sent = transport.recorded.filter { $0.url.path == "/api/sdk/v1/adservices" }.count
        return (sent, store)
    }

    func testKeyListMatchesKnownLegacyKeys() {
        XCTAssertEqual(HogClient.legacyAdServicesReportedKeys, [
            "revenuehog.adservices.reported",
            "attribution.adservices.reported",
            "adservices.attribution.reported",
            "adservices.reported",
        ])
    }

    private func assertSuppressed(_ key: String, file: StaticString = #filePath, line: UInt = #line) async {
        let (sent, store) = await run(legacy: [key: true])
        XCTAssertEqual(sent, 0, "\(key) should suppress capture", file: file, line: line)
        XCTAssertEqual(store.get("rh_adservices_sent"), "1", file: file, line: line)
        XCTAssertTrue(DiskQueue(directory: directory).load().isEmpty, file: file, line: line)
    }

    func testRevenueHogLegacyKeySuppressesCapture() async {
        await assertSuppressed("revenuehog.adservices.reported")
    }

    func testSkipperLegacyKeySuppressesCapture() async {
        await assertSuppressed("attribution.adservices.reported")
    }

    func testThoughtfulLegacyKeySuppressesCapture() async {
        await assertSuppressed("adservices.attribution.reported")
    }

    func testAIDropsLegacyKeySuppressesCapture() async {
        await assertSuppressed("adservices.reported")
    }

    func testNoLegacyKeyCaptureProceeds() async {
        let (sent, store) = await run(legacy: [:])
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(store.get("rh_adservices_sent"), "1")
    }

    func testLegacyKeyFalseCaptureProceeds() async {
        let (sent, _) = await run(legacy: Dictionary(
            uniqueKeysWithValues: HogClient.legacyAdServicesReportedKeys.map { ($0, false) }
        ))
        XCTAssertEqual(sent, 1)
    }

    func testUnrelatedKeyDoesNotSuppress() async {
        let (sent, _) = await run(legacy: ["something.else.reported": true])
        XCTAssertEqual(sent, 1)
    }
}
