import Foundation

/// All SDK state and networking lives on this actor. Every operation is
/// best-effort: failures are logged and queued, never thrown to the host app.
actor HogClient {
    private let apiKey: String
    private let options: Options
    private let transport: Transport
    private let storage: Storage
    private let queue: DiskQueue
    private let device: DeviceInfo
    private let log: Logger

    /// Seconds before retry n (0-indexed). Injectable so tests don't sleep.
    private let backoff: @Sendable (Int) -> TimeInterval

    init(
        apiKey: String,
        options: Options,
        transport: Transport = URLSessionTransport(),
        store: KeyValueStore = DefaultsStore(),
        queueDirectory: URL? = nil,
        device: DeviceInfo = .current(),
        backoff: @escaping @Sendable (Int) -> TimeInterval = { pow(2, Double($0)) * 0.5 }
    ) {
        self.apiKey = apiKey
        self.options = options
        self.transport = transport
        self.storage = Storage(store: store)
        self.device = device
        self.backoff = backoff
        self.log = Logger(level: options.logLevel)
        let dir = queueDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("revenuehog", isDirectory: true)
        self.queue = DiskQueue(directory: dir)
    }

    /// The id events are reported under right now: the identified user,
    /// or the persisted anonymous id before login.
    var appUserId: String { storage.userId ?? storage.anonymousId }

    // MARK: - Operations

    func identify(userId: String, attributes: [String: String]? = nil) async {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.warn("identify called with empty userId — ignored")
            return
        }
        storage.userId = trimmed
        await send("/api/sdk/v1/identify", identifyPayload(attributes: attributes))
        await reattributeSentTransactions(to: trimmed)
        await flush()
    }

    func setAttributes(_ attributes: [String: String]) async {
        await send("/api/sdk/v1/identify", identifyPayload(attributes: attributes))
    }

    func attribute(originalTransactionId: String, productId: String?) async {
        let user = appUserId
        if storage.sentTransactions[originalTransactionId] == user {
            log.debug("txn \(originalTransactionId) already attributed to \(user) — skipped")
            return
        }
        let payload = AttributePayload(
            appUserId: user,
            bundleId: device.bundleId,
            originalTransactionId: originalTransactionId,
            productId: productId
        )
        var sent = storage.sentTransactions
        sent[originalTransactionId] = user
        storage.sentTransactions = sent
        await send("/api/sdk/v1/attribute", payload)
    }

    /// Forgets the identified user and anonymous id (e.g. on logout).
    func reset() {
        storage.resetIdentity()
        queue.clear()
        log.info("reset — new anonymous id issued")
    }

    /// Replays queued requests in order; stops at the first failure.
    func flush() async {
        var pending = queue.load()
        guard !pending.isEmpty else { return }
        log.debug("flushing \(pending.count) queued request(s)")
        while !pending.isEmpty {
            let item = pending[0]
            guard await deliver(path: item.path, body: item.body, attempts: 1) else { break }
            pending.removeFirst()
        }
        queue.save(pending)
    }

    // MARK: - Internals

    private func identifyPayload(attributes: [String: String]?) -> IdentifyPayload {
        IdentifyPayload(
            appUserId: appUserId,
            bundleId: device.bundleId,
            platform: device.platform,
            osVersion: device.osVersion,
            deviceModel: device.deviceModel,
            locale: device.locale,
            attributes: attributes
        )
    }

    private func reattributeSentTransactions(to userId: String) async {
        for (txn, sentAs) in storage.sentTransactions where sentAs != userId {
            await attribute(originalTransactionId: txn, productId: nil)
        }
    }

    private func send(_ path: String, _ payload: some Encodable) async {
        guard let body = try? Payloads.encoder.encode(payload) else {
            log.error("failed to encode payload for \(path)")
            return
        }
        if await deliver(path: path, body: body, attempts: 3) {
            await flush()
        } else {
            queue.append(PendingRequest(path: path, body: body))
            log.info("queued \(path) for later delivery")
        }
    }

    /// Returns true when delivered (or permanently rejected — a request the
    /// server will never accept is dropped, not retried forever).
    private func deliver(path: String, body: Data, attempts: Int) async -> Bool {
        let url = options.baseURL.appendingPathComponent(path)
        let headers = [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
        ]
        for attempt in 0..<attempts {
            do {
                let status = try await transport.post(url: url, body: body, headers: headers)
                switch status {
                case 200..<300:
                    return true
                case 401:
                    log.error("401 from \(path) — check your publishable key (pk_live_…)")
                    return true // never accepted; don't retry forever
                case 429, 500..<600:
                    log.warn("\(status) from \(path) — backing off")
                default:
                    log.error("\(status) from \(path) — dropped")
                    return true
                }
            } catch {
                log.debug("network error on \(path): \(error.localizedDescription)")
            }
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: UInt64(backoff(attempt) * 1_000_000_000))
            }
        }
        return false
    }
}
