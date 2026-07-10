import Foundation

/// Tiny key/value seam so tests never touch real UserDefaults.
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

/// Typed accessors over the store. Persists the anonymous id (so purchases
/// attribute before login) and a map of originalTransactionId → the user id
/// it was last reported under (so `identify` can re-attribute).
struct Storage: Sendable {
    private let store: KeyValueStore

    init(store: KeyValueStore) { self.store = store }

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

    func resetIdentity() {
        store.set(nil, forKey: "rh_user_id")
        store.set(nil, forKey: "rh_sent_txns")
        store.set("$anon_" + UUID().uuidString.lowercased(), forKey: "rh_anonymous_id")
    }
}
