import Foundation
#if canImport(Security)
import Security
#endif

/// Tiny key/value seam so tests never touch real UserDefaults or Keychain.
protocol KeyValueStore: Sendable {
    func get(_ key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

final class DefaultsStore: KeyValueStore, @unchecked Sendable {
    private let defaults: UserDefaults

    init(suiteName: String = "dev.revenuehog.sdk") {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func get(_ key: String) -> String? { defaults.string(forKey: key) }

    func set(_ value: String?, forKey key: String) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

#if canImport(Security)
/// Keychain-backed store for the values worth protecting: the device token,
/// the App Attest key id, and the install id. Generic passwords under one
/// service, no access group, `AfterFirstUnlockThisDeviceOnly` and explicitly
/// non-synchronizable: everything here is DEVICE state — App Attest keys are
/// hardware-bound, and a synced or restored installId would clone one
/// experiment assignment across two devices.
final class KeychainStore: KeyValueStore, @unchecked Sendable {
    private let service: String

    init(service: String = "dev.revenuehog.sdk") {
        self.service = service
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String?, forKey key: String) {
        guard let value else {
            SecItemDelete(baseQuery(key) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        var add = baseQuery(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) == errSecDuplicateItem {
            SecItemUpdate(
                baseQuery(key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
#else
/// Platforms without Security.framework never attest anyway; fall back to
/// defaults storage so the package still compiles.
final class KeychainStore: KeyValueStore, @unchecked Sendable {
    private let fallback = DefaultsStore()

    init(service: String = "dev.revenuehog.sdk") {}

    func get(_ key: String) -> String? { fallback.get(key) }
    func set(_ value: String?, forKey key: String) { fallback.set(value, forKey: key) }
}
#endif

/// Typed accessors over the two stores. Identity state (anonymous id,
/// sent-transaction map) lives in defaults; enrollment credentials (device
/// token, App Attest key id) live in the Keychain.
struct Storage: Sendable {
    private let store: KeyValueStore
    private let secure: KeyValueStore

    init(store: KeyValueStore, secure: KeyValueStore) {
        self.store = store
        self.secure = secure
    }

    var anonymousId: String {
        if let existing = store.get("rh_anonymous_id") { return existing }
        let fresh = "$anon_" + UUID().uuidString.lowercased()
        store.set(fresh, forKey: "rh_anonymous_id")
        return fresh
    }

    var userId: String? {
        get { store.get("rh_user_id") }
        nonmutating set { store.set(newValue, forKey: "rh_user_id") }
    }

    /// originalTransactionId → appUserId it was last sent as.
    var sentTransactions: [String: String] {
        get {
            guard let raw = store.get("rh_sent_txns")?.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: String].self, from: raw)
            else { return [:] }
            return map
        }
        nonmutating set {
            let data = try? JSONEncoder().encode(newValue)
            store.set(data.flatMap { String(data: $0, encoding: .utf8) }, forKey: "rh_sent_txns")
        }
    }

    /// Server-minted `dt_…` credential from App Attest enrollment.
    var deviceToken: String? {
        get { secure.get("rh_device_token") }
        nonmutating set { secure.set(newValue, forKey: "rh_device_token") }
    }

    /// App Attest key id, persisted so retries reuse the same key.
    var attestKeyId: String? {
        get { secure.get("rh_attest_key_id") }
        nonmutating set { secure.set(newValue, forKey: "rh_attest_key_id") }
    }

    /// One UUID per install, minted lazily and kept in the Keychain so it
    /// survives reinstalls. It exists ONLY so paywall experiment assignment
    /// sticks to this device; it is not an identity and survives `reset()`.
    /// The Keychain items are non-synchronizable and device-only (see
    /// KeychainStore): an iCloud-synced installId would clone one
    /// assignment across a person's devices.
    var installId: String {
        if let existing = secure.get("rh_install_id") { return existing }
        let fresh = UUID().uuidString
        secure.set(fresh, forKey: "rh_install_id")
        return fresh
    }

    /// Per-entitlement paywall answers (see CachedPaywall in Paywall.swift).
    /// Lives in defaults, not the Keychain: it is a config cache, and a
    /// reinstall SHOULD refetch.
    var paywallCache: [String: CachedPaywall] {
        get {
            guard let raw = store.get("rh_paywall_cache")?.data(using: .utf8),
                  let map = try? JSONDecoder().decode([String: CachedPaywall].self, from: raw)
            else { return [:] }
            return map
        }
        nonmutating set {
            if newValue.isEmpty {
                store.set(nil, forKey: "rh_paywall_cache")
                return
            }
            let data = try? JSONEncoder().encode(newValue)
            store.set(data.flatMap { String(data: $0, encoding: .utf8) }, forKey: "rh_paywall_cache")
        }
    }

    /// Enrollment is not retried before this instant (set after the server
    /// says the app is not connected to any org yet).
    var attestBackoffUntil: Date? {
        get {
            store.get("rh_attest_backoff_until")
                .flatMap(Double.init)
                .map(Date.init(timeIntervalSince1970:))
        }
        nonmutating set {
            store.set(
                newValue.map { String($0.timeIntervalSince1970) },
                forKey: "rh_attest_backoff_until"
            )
        }
    }

    /// Forgets who the user is. Enrollment credentials are device-scoped,
    /// not user-scoped, so they survive.
    func resetIdentity() {
        store.set(nil, forKey: "rh_user_id")
        store.set(nil, forKey: "rh_sent_txns")
        store.set("$anon_" + UUID().uuidString.lowercased(), forKey: "rh_anonymous_id")
    }
}
