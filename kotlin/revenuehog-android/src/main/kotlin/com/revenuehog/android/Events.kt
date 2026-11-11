package com.revenuehog.android

import org.json.JSONArray
import org.json.JSONObject

/** What kind of feedback the user is sending. */
enum class FeedbackKind(val wire: String) {
    BUG("bug"),
    IDEA("idea"),
    QUESTION("question"),
    PRAISE("praise"),
}

/** Outcome of [RevenueHog.sendFeedback]. Never thrown, always delivered to the callback. */
sealed class FeedbackResult {
    /** Stored by RevenueHog; [id] is the server's feedback id when it sent one. */
    data class Sent(val id: String?) : FeedbackResult()

    /** Offline or rate limited: persisted and delivered on a later flush or launch. */
    object Queued : FeedbackResult()

    /** Invalid input, or a request the server will never accept. Not retried. */
    data class Rejected(val reason: String) : FeedbackResult()
}

/** Client-side mirrors of the server's event and feedback validation. */
internal object EventRules {
    const val MAX_BATCH = 50
    const val BATCH_THRESHOLD = 20
    const val MAX_BUFFERED = 1_000
    const val MAX_PROPERTIES_BYTES = 2_048
    const val MAX_FEEDBACK_MESSAGE = 5_000
    const val MAX_FEEDBACK_JSON_BYTES = 8_192
    private val NAME = Regex("^[a-z][a-z0-9_]*$")

    /** snake_case, starts with a letter, max 48 chars, `rh_` is reserved. */
    fun validName(raw: String?): String? {
        val name = raw?.trim() ?: return null
        if (name.isEmpty() || name.length > 48 || name.startsWith("rh_") || !NAME.matches(name)) return null
        return name
    }

    /** Flat event properties: strings, numbers, booleans and nulls only. */
    fun properties(map: Map<String, Any?>?): JSONObject? {
        if (map.isNullOrEmpty()) return null
        val json = JSONObject()
        for ((key, value) in map) {
            when (value) {
                null -> json.put(key, JSONObject.NULL)
                is String, is Boolean, is Int, is Long, is Double, is Float -> json.put(key, value)
                is Number -> json.put(key, value.toDouble())
                else -> json.put(key, value.toString())
            }
        }
        return json
    }

    /** Any JSON-shaped map (nested maps and lists allowed) for feedback data/metadata. */
    fun objectOf(map: Map<String, Any?>): JSONObject {
        val json = JSONObject()
        for ((key, value) in map) json.put(key, wrap(value))
        return json
    }

    private fun wrap(value: Any?): Any = when (value) {
        null -> JSONObject.NULL
        is String, is Boolean, is Int, is Long, is Double -> value
        is Float -> value.toDouble()
        is Number -> value.toDouble()
        is Map<*, *> -> JSONObject().also { obj ->
            for ((k, v) in value) obj.put(k.toString(), wrap(v))
        }
        is Iterable<*> -> JSONArray().also { arr -> value.forEach { arr.put(wrap(it)) } }
        else -> value.toString()
    }

    fun bytes(json: Any): Int = json.toString().toByteArray(Charsets.UTF_8).size
}
