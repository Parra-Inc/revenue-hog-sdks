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
