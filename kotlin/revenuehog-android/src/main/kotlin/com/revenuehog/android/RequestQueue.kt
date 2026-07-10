package com.revenuehog.android

import org.json.JSONArray
import org.json.JSONObject

internal data class PendingRequest(val path: String, val body: String)

/**
 * FIFO queue of undelivered requests, persisted through the [KeyValueStore].
 * Both API endpoints are idempotent, so replays are safe. Only touched from
 * the client's single-threaded executor.
 */
internal class RequestQueue(
    private val store: KeyValueStore,
    private val maxCount: Int = 100,
) {
    fun load(): List<PendingRequest> = try {
        val raw = store.get(KEY) ?: return emptyList()
        val array = JSONArray(raw)
        (0 until array.length()).mapNotNull { i ->
            val item = array.optJSONObject(i) ?: return@mapNotNull null
            PendingRequest(item.getString("path"), item.getString("body"))
        }
    } catch (_: Throwable) {
        emptyList()
    }

    fun save(items: List<PendingRequest>) {
        try {
            if (items.isEmpty()) {
                store.put(KEY, null)
                return
            }
            val array = JSONArray()
            for (item in items) {
                array.put(JSONObject().put("path", item.path).put("body", item.body))
            }
            store.put(KEY, array.toString())
        } catch (_: Throwable) {
            // storage failed — drop silently, never crash the host
        }
    }

    /** Appends, dropping the oldest entries beyond [maxCount]. */
    fun append(item: PendingRequest) {
        save((load() + item).takeLast(maxCount))
    }

    fun clear() = save(emptyList())

    private companion object {
        const val KEY = "rh_queue"
    }
}
