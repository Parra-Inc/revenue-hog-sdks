import Foundation
@testable import RevenueHog

/// In-memory KeyValueStore so tests never touch UserDefaults or Keychain.
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
/// runs dry every request succeeds with 200 and an empty body.
final class MockTransport: Transport, @unchecked Sendable {
    enum Response {
        case status(Int)
        case json(Int, String)
        case networkError
        /// Never answers (until task cancellation): the slow-network case
        /// the paywall timeout races against.
        case hang
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

    func post(url: URL, body: Data, headers: [String: String]) async throws -> TransportResponse {
        switch record(RecordedRequest(url: url, body: body, headers: headers)) {
        case .status(let code): return TransportResponse(status: code, body: Data())
        case .json(let code, let json): return TransportResponse(status: code, body: Data(json.utf8))
        case .networkError: throw URLError(.notConnectedToInternet)
        case .hang:
            try await Task.sleep(nanoseconds: 30_000_000_000)
            throw URLError(.timedOut)
        }
    }

    private func record(_ request: RecordedRequest) -> Response {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return script.isEmpty ? .status(200) : script.removeFirst()
    }
}

/// Scriptable AttestService. Results are consumed in order; once a script
/// runs dry, calls succeed with generated defaults.
final class FakeAttestService: AttestService, @unchecked Sendable {
    private let lock = NSLock()
    var supported = true
    /// When true, `attestKey` never returns (simulates slow enrollment).
    var hangs = false
    var generateKeyResults: [Result<String, Error>] = []
    var attestKeyResults: [Result<Data, Error>] = []
    private(set) var generateKeyCalls = 0
    private(set) var attestKeyCalls: [(keyId: String, clientDataHash: Data)] = []

    var isSupported: Bool { supported }

    func generateKey() async throws -> String {
        try nextKeyResult().get()
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        if hangs {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        return try nextAttestResult(keyId: keyId, clientDataHash: clientDataHash).get()
    }

    private func nextKeyResult() -> Result<String, Error> {
        lock.lock(); defer { lock.unlock() }
        generateKeyCalls += 1
        return generateKeyResults.isEmpty
            ? .success("key_\(generateKeyCalls)")
            : generateKeyResults.removeFirst()
    }

    private func nextAttestResult(keyId: String, clientDataHash: Data) -> Result<Data, Error> {
        lock.lock(); defer { lock.unlock() }
        attestKeyCalls.append((keyId, clientDataHash))
        return attestKeyResults.isEmpty
            ? .success(Data("fake-attestation".utf8))
            : attestKeyResults.removeFirst()
    }
}

enum TestSupport {
    static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rh-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A secure store that already holds a device token, so tests not
    /// about enrollment skip it entirely.
    static func enrolledSecureStore(token: String = "dt_test_123") -> MemoryStore {
        let store = MemoryStore()
        store.set(token, forKey: "rh_device_token")
        return store
    }

    static func makeClient(
        transport: MockTransport,
        store: KeyValueStore = MemoryStore(),
        secureStore: KeyValueStore = enrolledSecureStore(),
        attestService: AttestService = FakeAttestService(),
        queueDirectory: URL = tempDirectory(),
        isSimulator: Bool = false,
        enrollmentWait: TimeInterval = 5,
        paywallTimeout: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> HogClient {
        HogClient(
            options: Options(
                baseURL: URL(string: "https://example.test")!,
                logLevel: .silent
            ),
            transport: transport,
            store: store,
            secureStore: secureStore,
            attestService: attestService,
            queueDirectory: queueDirectory,
            device: DeviceInfo(
                bundleId: "com.example.app",
                platform: "ios",
                osVersion: "17.0.0",
                deviceModel: "iPhone15,2",
                locale: "en_US"
            ),
            isSimulator: isSimulator,
            enrollmentWait: enrollmentWait,
            paywallTimeout: paywallTimeout,
            now: now,
            backoff: { _ in 0 }
        )
    }
}
