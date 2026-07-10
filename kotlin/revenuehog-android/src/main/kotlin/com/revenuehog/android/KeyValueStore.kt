package com.revenuehog.android

/**
 * Tiny persistence seam. Production uses SharedPreferences (see
 * [RevenueHog.configure]); JVM unit tests use an in-memory map.
 */
interface KeyValueStore {
    fun get(key: String): String?

    /** `null` removes the key. */
    fun put(key: String, value: String?)
}
