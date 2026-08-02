import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Seam over `DCAppAttestService` so the enrollment state machine is
/// testable without a device. The real implementation is below; tests
/// inject a fake.
protocol AttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// Errors the state machine reacts to. The real service maps `DCError`
/// codes onto these so nothing outside this file imports DeviceCheck.
enum AttestServiceError: Error, Equatable {
    /// Apple's attestation service is temporarily down. Retry, same key.
    case serverUnavailable
    /// The key was rejected. Discard it and generate a fresh one, once.
    case invalidKey
}

/// Why a request is going out without a device token. Sent as the value
/// of `X-RevenueHog-Unattested` so the server can label the write.
enum UnattestedReason: String, Sendable {
    case pending
    case unsupported
    case simulator
    case enrollFailed = "enroll-failed"
}

/// How enrollment resolved for this session.
enum AttestationOutcome: Equatable, Sendable {
    case enrolled(deviceToken: String)
    case unattested(UnattestedReason)
}

/// One-time App Attest enrollment: challenge → attestKey → device token.
/// Run once per install by `HogClient`; every outcome is final for the
/// session and never throws to the caller.
struct Attestation: Sendable {
    let service: AttestService
    let transport: Transport
    let baseURL: URL
    let bundleId: String
    let storage: Storage
    let log: Logger
    let isSimulator: Bool
    let now: @Sendable () -> Date
    /// Seconds before retry n (0-indexed). Shared with `HogClient`.
    let backoff: @Sendable (Int) -> TimeInterval

    /// In-session attempts when Apple's service is unavailable.
    static let maxAttempts = 3

    private enum EnrollError: Error {
        case badResponse
        case serverRejected(Int)
    }

    func enroll() async -> AttestationOutcome {
        if let token = storage.deviceToken {
            return .enrolled(deviceToken: token)
        }
        if isSimulator {
            return .unattested(.simulator)
        }
        guard service.isSupported else {
            return .unattested(.unsupported)
        }
        if let until = storage.attestBackoffUntil, until > now() {
            log.debug("enrollment backing off until \(until)")
            return .unattested(.enrollFailed)
        }
        var regenerated = false
        for attempt in 0..<Self.maxAttempts {
            do {
                return try await attemptEnrollment()
            } catch AttestServiceError.serverUnavailable {
                // Apple guidance: keep the key, try again later.
                log.warn("App Attest temporarily unavailable, retrying")
                if attempt < Self.maxAttempts - 1 {
                    try? await Task.sleep(nanoseconds: UInt64(backoff(attempt) * 1_000_000_000))
                }
            } catch AttestServiceError.invalidKey where !regenerated {
                log.warn("App Attest key rejected, regenerating once")
                regenerated = true
                storage.attestKeyId = nil
            } catch let EnrollError.serverRejected(status) where status == 404 || status == 409 {
                // App not connected to any org yet. Back off a day so a
                // pre-launch install does not hammer the endpoint.
                log.warn("\(status) from /attest, app not connected yet, backing off 24h")
                storage.attestBackoffUntil = now().addingTimeInterval(24 * 60 * 60)
                return .unattested(.enrollFailed)
            } catch {
                log.warn("enrollment failed (\(error)), will retry next launch")
                return .unattested(.enrollFailed)
            }
        }
        return .unattested(.enrollFailed)
    }

    private func attemptEnrollment() async throws -> AttestationOutcome {
        let keyId: String
        if let existing = storage.attestKeyId {
            keyId = existing
        } else {
            keyId = try await service.generateKey()
            storage.attestKeyId = keyId
        }
        // Challenges are single-use, so every attempt fetches a fresh one.
        let challenge = try await fetchChallenge()
        guard let challengeBytes = Data(base64URLEncoded: challenge) else {
            throw EnrollError.badResponse
        }
        let attestationObject = try await service.attestKey(
            keyId, clientDataHash: sha256(challengeBytes)
        )
        let token = try await exchange(
            keyId: keyId, attestation: attestationObject, challenge: challenge
        )
        storage.deviceToken = token
        log.info("device enrolled")
        return .enrolled(deviceToken: token)
    }

    private func fetchChallenge() async throws -> String {
        let response = try await transport.post(
            url: baseURL.appendingPathComponent("/api/sdk/v1/attest/challenge"),
            body: Data("{}".utf8),
            headers: ["Content-Type": "application/json"]
        )
        guard (200..<300).contains(response.status) else {
            throw EnrollError.serverRejected(response.status)
        }
        guard let decoded = try? JSONDecoder().decode(
            AttestChallengeResponse.self, from: response.body
        ) else {
            throw EnrollError.badResponse
        }
        return decoded.challenge
    }

    private func exchange(
        keyId: String, attestation: Data, challenge: String
    ) async throws -> String {
        let payload = AttestPayload(
            keyId: keyId,
            attestation: attestation.base64EncodedString(),
            challenge: challenge,
            bundleId: bundleId
        )
        let body = try Payloads.encoder.encode(payload)
        let response = try await transport.post(
            url: baseURL.appendingPathComponent("/api/sdk/v1/attest"),
            body: body,
            headers: ["Content-Type": "application/json"]
        )
        guard (200..<300).contains(response.status) else {
            throw EnrollError.serverRejected(response.status)
        }
        guard let decoded = try? JSONDecoder().decode(
            AttestResponse.self, from: response.body
        ) else {
            throw EnrollError.badResponse
        }
        return decoded.deviceToken
    }

    private func sha256(_ data: Data) -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: data))
        #else
        // No CryptoKit means no DeviceCheck either; never reached.
        return Data()
        #endif
    }
}

extension Data {
    /// Decodes base64url (RFC 4648 §5, no padding) as sent in challenges.
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}

// MARK: - Platform implementations

#if canImport(DeviceCheck)
import DeviceCheck

/// The real thing. Calls go straight to `DCAppAttestService.shared`;
/// `DCError` codes are mapped so the state machine stays DeviceCheck-free.
@available(iOS 14.0, macOS 11.0, tvOS 15.0, watchOS 9.0, *)
struct AppAttestService: AttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        do { return try await DCAppAttestService.shared.generateKey() }
        catch { throw Self.mapped(error) }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        do {
            return try await DCAppAttestService.shared.attestKey(
                keyId, clientDataHash: clientDataHash
            )
        } catch { throw Self.mapped(error) }
    }

    private static func mapped(_ error: Error) -> Error {
        switch (error as? DCError)?.code {
        case .serverUnavailable: return AttestServiceError.serverUnavailable
        case .invalidKey: return AttestServiceError.invalidKey
        default: return error
        }
    }
}
#endif

/// Stand-in for platforms and OS versions without App Attest.
/// `isSupported` is false, so enrollment resolves unattested immediately.
struct UnsupportedAttestService: AttestService {
    var isSupported: Bool { false }

    func generateKey() async throws -> String { throw AttestServiceError.invalidKey }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        throw AttestServiceError.invalidKey
    }
}

enum PlatformAttestService {
    static func make() -> AttestService {
        #if canImport(DeviceCheck)
        if #available(iOS 14.0, macOS 11.0, tvOS 15.0, watchOS 9.0, *) {
            return AppAttestService()
        }
        #endif
        return UnsupportedAttestService()
    }
}
