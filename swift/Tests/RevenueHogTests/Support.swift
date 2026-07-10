import Foundation
@testable import RevenueHog

/// In-memory KeyValueStore so tests never touch UserDefaults.
final class MemoryStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ value: String?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

struct RecordedRequest {
    let url: URL
    let body: Data
    let headers: [String: String]

    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

/// Scriptable transport. Responses are consumed in order; once the script
/// runs dry every request succeeds with 200.
final class MockTransport: Transport, @unchecked Sendable {
    enum Response {
        case status(Int)
        case networkError
    }

    private let lock = NSLock()
    private var script: [Response]
    private(set) var requests: [RecordedRequest] = []

    init(script: [Response] = []) {
        self.script = script
    }

    var recorded: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func post(url: URL, body: Data, headers: [String: String]) async throws -> Int {
        lock.lock()
        requests.append(RecordedRequest(url: url, body: body, headers: headers))
        let response = script.isEmpty ? .status(200) : script.removeFirst()
        lock.unlock()
        switch response {
        case .status(let code): return code
        case .networkError: throw URLError(.notConnectedToInternet)
        }
    }
}

enum TestSupport {
    static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rh-tests-\(UUID().uuidString)", isDirectory: true)
    }

    static func makeClient(
        transport: MockTransport,
        store: KeyValueStore = MemoryStore(),
        queueDirectory: URL = tempDirectory()
    ) -> HogClient {
        HogClient(
            apiKey: "pk_test_123",
            options: Options(
                baseURL: URL(string: "https://example.test")!,
                logLevel: .silent
            ),
            transport: transport,
            store: store,
            queueDirectory: queueDirectory,
            device: DeviceInfo(
                bundleId: "com.example.app",
                platform: "ios",
                osVersion: "17.0.0",
                deviceModel: "iPhone15,2",
                locale: "en_US"
            ),
            backoff: { _ in 0 }
        )
    }
}
