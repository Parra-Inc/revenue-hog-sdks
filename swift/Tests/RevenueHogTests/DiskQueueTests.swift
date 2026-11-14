import XCTest
@testable import RevenueHog

final class DiskQueueTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = TestSupport.tempDirectory()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testAppendAndLoadRoundTrip() {
        let queue = DiskQueue(directory: directory)
        queue.append(PendingRequest(path: "/a", body: Data("1".utf8)))
        queue.append(PendingRequest(path: "/b", body: Data("2".utf8)))

        let items = queue.load()
        XCTAssertEqual(items.map(\.path), ["/a", "/b"])
        XCTAssertEqual(items.map { String(decoding: $0.body, as: UTF8.self) }, ["1", "2"])
    }

    func testPersistsAcrossInstances() {
        DiskQueue(directory: directory)
            .append(PendingRequest(path: "/a", body: Data()))

        let reloaded = DiskQueue(directory: directory).load()
        XCTAssertEqual(reloaded.map(\.path), ["/a"])
    }

    func testCapsAtMaxCountDroppingOldest() {
        let queue = DiskQueue(directory: directory, maxCount: 3)
        for i in 1...5 {
            queue.append(PendingRequest(path: "/\(i)", body: Data()))
        }
        XCTAssertEqual(queue.load().map(\.path), ["/3", "/4", "/5"])
    }

    /// The head is the one copy a flush delivered. When it is something else,
    /// the delivered one was evicted, and an equal copy behind it is still due.
    func testRemoveHeadTakesOnlyTheHead() {
        let queue = DiskQueue(directory: directory)
        let item = PendingRequest(path: "/a", body: Data("1".utf8))
        queue.append(item)
        queue.append(PendingRequest(path: "/b", body: Data()))
        queue.append(item)

        XCTAssertTrue(queue.removeHead(item))
        XCTAssertEqual(queue.load().map(\.path), ["/b", "/a"])

        XCTAssertTrue(queue.removeHead(item))
        XCTAssertEqual(queue.load().map(\.path), ["/b", "/a"])
    }

    func testRemoveHeadOfAnItemNoLongerQueuedDoesNothing() {
        let queue = DiskQueue(directory: directory)
        let item = PendingRequest(path: "/a", body: Data())
        queue.append(item)
        queue.clear()

        XCTAssertTrue(queue.removeHead(item))

        XCTAssertEqual(queue.load().count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queue.fileURL.path))
    }

    func testAnEventBatchNeverMakesRoomForItself() {
        let queue = DiskQueue(directory: directory, maxCount: 2)
        queue.append(PendingRequest(path: "/a", body: Data()))
        queue.append(PendingRequest(path: HogClient.eventsPath, body: Data("old".utf8)))

        let kept = queue.append(PendingRequest(path: HogClient.eventsPath, body: Data("new".utf8)))

        XCTAssertFalse(kept)
        XCTAssertEqual(queue.load().map { String(decoding: $0.body, as: UTF8.self) }, ["", "old"])
    }

    func testRoomIsTakenFromEventBatchesFirst() {
        let queue = DiskQueue(directory: directory, maxCount: 3)
        queue.append(PendingRequest(path: "/a", body: Data()))
        queue.append(PendingRequest(path: HogClient.eventsPath, body: Data("1".utf8)))
        queue.append(PendingRequest(path: HogClient.eventsPath, body: Data("2".utf8)))

        XCTAssertTrue(queue.append(PendingRequest(path: "/b", body: Data())))
        XCTAssertEqual(queue.load().map(\.path), ["/a", HogClient.eventsPath, "/b"])
        XCTAssertEqual(String(decoding: queue.load()[1].body, as: UTF8.self), "2")

        XCTAssertTrue(queue.append(PendingRequest(path: "/c", body: Data())))
        XCTAssertEqual(queue.load().map(\.path), ["/a", "/b", "/c"])

        // No batch left: the oldest goes, as it always did.
        XCTAssertTrue(queue.append(PendingRequest(path: "/d", body: Data())))
        XCTAssertEqual(queue.load().map(\.path), ["/b", "/c", "/d"])
    }

    func testAWriteThatFailsIsReported() throws {
        let queue = DiskQueue(directory: directory)
        let item = PendingRequest(path: "/a", body: Data())
        queue.append(item)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        try XCTSkipIf(FileManager.default.isWritableFile(atPath: directory.path), "root writes anyway")

        XCTAssertFalse(queue.removeHead(item))
        XCTAssertFalse(queue.append(PendingRequest(path: "/b", body: Data())))
        XCTAssertEqual(queue.load(), [item])
    }

    func testClearRemovesEverything() {
        let queue = DiskQueue(directory: directory)
        queue.append(PendingRequest(path: "/a", body: Data()))
        queue.clear()
        XCTAssertEqual(queue.load(), [])
    }

    func testLoadOnCorruptFileReturnsEmpty() throws {
        let queue = DiskQueue(directory: directory)
        try Data("not json".utf8).write(to: queue.fileURL)
        XCTAssertEqual(queue.load(), [])
    }
}
