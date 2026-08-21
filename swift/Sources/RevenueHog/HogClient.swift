import Foundation
#if canImport(StoreKit)
import StoreKit
#endif

/// All SDK state and networking lives on this actor. Every operation is
/// best-effort: failures are logged and queued, never thrown to the host app.
actor HogClient {
    // Internal (not private): Paywall.swift extends this actor from its own
    // file and shares the plumbing.
    let options: Options
    let transport: Transport
    let storage: Storage
    private let queue: DiskQueue
    let device: DeviceInfo
    let log: Logger
    private let attestation: Attestation

    /// Longest a request waits for enrollment before going out unattested.
    private let enrollmentWait: TimeInterval

    /// Deadline for the paywall fetch: the money path resolves fast and
    /// falls back rather than blocking a paywall on a slow network.
    let paywallTimeout: TimeInterval

    /// StoreKit's AppTransaction environment ("Production" | "Sandbox" |
    /// "Xcode"), resolved in the background after start(). Sent on paywall
    /// fetches so TestFlight and dev traffic are visible in experiment
    /// results; nil (omitted) until resolution lands.
    private(set) var storeEnvironment: String?

    /// Seconds before retry n (0-indexed). Injectable so tests don't sleep.
    private let backoff: @Sendable (Int) -> TimeInterval

    private var enrollmentTask: Task<Void, Never>?
    private var attestationOutcome: AttestationOutcome?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var reenrolledAfter401 = false

    init(
        options: Options,
        transport: Transport = URLSessionTransport(),
        store: KeyValueStore = DefaultsStore(),
        secureStore: KeyValueStore = KeychainStore(),
        attestService: AttestService = PlatformAttestService.make(),
        queueDirectory: URL? = nil,
        device: DeviceInfo = .current(),
        isSimulator: Bool = DeviceInfo.isSimulator,
        enrollmentWait: TimeInterval = 10,
        paywallTimeout: TimeInterval = 2.5,
        now: @escaping @Sendable () -> Date = { Date() },
        backoff: @escaping @Sendable (Int) -> TimeInterval = { pow(2, Double($0)) * 0.5 }
    ) {
        self.options = options
        self.transport = transport
        self.storage = Storage(store: store, secure: secureStore)
        self.device = device
        self.backoff = backoff
        self.enrollmentWait = enrollmentWait
        self.paywallTimeout = paywallTimeout
        let log = Logger(level: options.logLevel)
        self.log = log
        let dir = queueDirectory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("revenuehog", isDirectory: true)
        self.queue = DiskQueue(directory: dir)
        self.attestation = Attestation(
            service: attestService,
            transport: transport,
            baseURL: options.baseURL,
            bundleId: device.bundleId,
            storage: storage,
            log: log,
            isSimulator: isSimulator,
            now: now,
            backoff: backoff
        )
    }

    /// The id events are reported under right now: the identified user,
    /// or the persisted anonymous id before login.
    var appUserId: String { storage.userId ?? storage.anonymousId }

    // MARK: - Operations

    /// Called once from `configure()`: kicks off App Attest enrollment and
    /// replays anything still queued from a previous launch.
    func start() async {
        ensureEnrollmentStarted()
        startStoreEnvironmentResolution()
        await flush()
    }

    func identify(userId: String, attributes: [String: String]? = nil) async {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            log.warn("identify called with empty userId, ignored")
            return
        }
        if storage.userId != trimmed {
            // The appUserId sent on paywall fetches is how purchases join
            // experiment results; a cached answer from the old identity
            // would leave the new one unlinked.
            storage.paywallCache = [:]
        }
        storage.userId = trimmed
        await send("/api/sdk/v1/identify", identifyPayload(attributes: attributes))
        await reattributeSentTransactions(to: trimmed)
        await flush()
    }

    func setAttributes(_ attributes: [String: String]) async {
        await send("/api/sdk/v1/identify", identifyPayload(attributes: attributes))
    }

    func attribute(originalTransactionId: String, productId: String?, jws: String? = nil) async {
        let user = appUserId
        if storage.sentTransactions[originalTransactionId] == user {
            log.debug("txn \(originalTransactionId) already attributed to \(user), skipped")
            return
        }
        let payload = AttributePayload(
            appUserId: user,
            bundleId: device.bundleId,
            originalTransactionId: originalTransactionId,
            productId: productId,
            jws: jws
        )
        var sent = storage.sentTransactions
        sent[originalTransactionId] = user
        storage.sentTransactions = sent
        await send("/api/sdk/v1/attribute", payload)
    }

    /// Forgets the identified user and anonymous id (e.g. on logout).
    /// Device enrollment survives; it is not tied to a user, and so does
    /// the installId (it keys experiment assignment to the DEVICE).
    func reset() {
        storage.resetIdentity()
        storage.paywallCache = [:]
        queue.clear()
        log.info("reset, new anonymous id issued")
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

    // MARK: - Store environment

    /// Resolves the StoreKit environment once, off the hot path. Best-effort:
    /// platforms and OS versions without AppTransaction simply omit the
    /// field, which the server reads as Production.
    private func startStoreEnvironmentResolution() {
        guard storeEnvironment == nil else { return }
        #if canImport(StoreKit)
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            Task.detached(priority: .utility) { [weak self] in
                guard let result = try? await AppTransaction.shared,
                      case .verified(let transaction) = result
                else { return }
                await self?.setStoreEnvironment(transaction.environment.rawValue)
            }
        }
        #endif
    }

    func setStoreEnvironment(_ environment: String) {
        storeEnvironment = environment
    }

    // MARK: - Attestation state

    private func ensureEnrollmentStarted() {
        guard enrollmentTask == nil, attestationOutcome == nil else { return }
        let attestation = self.attestation
        enrollmentTask = Task {
            let outcome = await attestation.enroll()
            self.enrollmentResolved(outcome)
        }
    }

    /// The session's attestation outcome, waiting up to `enrollmentWait`
    /// for in-flight enrollment. Times out to `.pending` (request goes
    /// unattested; a later request can still pick up the token).
    private func resolveAttestation() async -> AttestationOutcome {
        if let outcome = attestationOutcome { return outcome }
        ensureEnrollmentStarted()
        await waitForResolution(upTo: enrollmentWait)
        return attestationOutcome ?? .unattested(.pending)
    }

    private func enrollmentResolved(_ outcome: AttestationOutcome) {
        attestationOutcome = outcome
        for continuation in waiters.values { continuation.resume() }
        waiters.removeAll()
    }

    /// The outcome as it stands RIGHT NOW, no waiting. The paywall path
    /// uses this: on a fresh install the enrollment grace would block the
    /// money path, and the quarantine path answers unattested calls fine.
    func currentAttestation() -> AttestationOutcome {
        attestationOutcome ?? .unattested(.pending)
    }

    /// Parks the caller until enrollment resolves or the deadline passes,
    /// whichever comes first. Enrollment itself is never cancelled.
    private func waitForResolution(upTo timeout: TimeInterval) async {
        guard attestationOutcome == nil else { return }
        let id = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters[id] = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.timeOutWaiter(id)
            }
        }
    }

    private func timeOutWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume()
    }

    /// A 401 with a token means the server no longer accepts it. Clear it
    /// and re-enroll once per session; a second 401 goes unattested.
    private func handleUnauthorized() {
        storage.deviceToken = nil
        if reenrolledAfter401 {
            log.error("401 after re-enrollment, continuing unattested this session")
            attestationOutcome = .unattested(.enrollFailed)
            enrollmentTask = nil
        } else {
            reenrolledAfter401 = true
            log.warn("401 with device token, re-enrolling once")
            attestationOutcome = nil
            let attestation = self.attestation
            enrollmentTask = Task {
                let outcome = await attestation.enroll()
                self.enrollmentResolved(outcome)
            }
        }
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

    /// Enrolled requests carry the device token; everything else says why
    /// it doesn't, so the server can label the write.
    private func requestHeaders() async -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        switch await resolveAttestation() {
        case .enrolled(let token):
            headers["Authorization"] = "Bearer \(token)"
        case .unattested(let reason):
            headers["X-RevenueHog-Unattested"] = reason.rawValue
        }
        return headers
    }

    /// Returns true when delivered (or permanently rejected; a request the
    /// server will never accept is dropped, not retried forever).
    func deliver(path: String, body: Data, attempts: Int) async -> Bool {
        let url = options.baseURL.appendingPathComponent(path)
        var attempt = 0
        while attempt < attempts {
            let headers = await requestHeaders()
            do {
                let response = try await transport.post(url: url, body: body, headers: headers)
                switch response.status {
                case 200..<300:
                    return true
                case 401:
                    guard headers["Authorization"] != nil else {
                        log.error("401 from \(path) while unattested, dropped")
                        return true // never accepted; don't retry forever
                    }
                    handleUnauthorized()
                    continue // resend with refreshed auth; bounded by handleUnauthorized
                case 429, 500..<600:
                    log.warn("\(response.status) from \(path), backing off")
                default:
                    log.error("\(response.status) from \(path), dropped")
                    return true
                }
            } catch {
                log.debug("network error on \(path): \(error.localizedDescription)")
            }
            attempt += 1
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: UInt64(backoff(attempt - 1) * 1_000_000_000))
            }
        }
        return false
    }
}
