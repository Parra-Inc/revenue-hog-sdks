package com.revenuehog.android

import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executor

/**
 * All SDK state and networking. Every public entry point runs on [executor]
 * (a single background thread in production) and swallows every failure —
 * nothing here ever crashes the host app.
 */
internal class HogClient(
    private val apiKey: String,
    private val options: Options,
    private val device: DeviceInfo,
    private val store: KeyValueStore,
    private val transport: Transport = HttpUrlConnectionTransport(),
    private val executor: Executor,
    /** ms before retry n (0-indexed). Tests inject `{ 0 }`. */
    private val backoffMs: (Int) -> Long = { attempt -> 500L shl attempt },
    private val sleep: (Long) -> Unit = { Thread.sleep(it) },
    logSink: ((String) -> Unit)? = null,
) {
    private val log = logSink
        ?.let { Logger(options.logLevel, it) }
        ?: Logger(options.logLevel)
    private val queue = RequestQueue(store)

    // ── public surface (all fire-and-forget, all crash-proof) ──────────────

    fun identify(userId: String, attributes: Map<String, String>? = null) = run {
        val trimmed = userId.trim()
        if (trimmed.isEmpty()) {
            log.warn("identify called with empty userId — ignored")
            return@run
        }
        store.put(KEY_USER_ID, trimmed)
        send(Payloads.IDENTIFY_PATH, Payloads.identify(trimmed, device, attributes))
        reattributeSentTransactions(trimmed)
        flushQueue()
    }

    fun setAttributes(attributes: Map<String, String>) = run {
        send(Payloads.IDENTIFY_PATH, Payloads.identify(appUserId(), device, attributes))
    }

    fun attributePurchase(originalTransactionId: String, productId: String? = null) = run {
        attributeNow(originalTransactionId.trim(), productId)
    }

    fun reset() = run {
        store.put(KEY_USER_ID, null)
        store.put(KEY_SENT_TXNS, null)
        store.put(KEY_ANON_ID, freshAnonId())
        queue.clear()
        log.info("reset — new anonymous id issued")
    }

    fun flush() = run { flushQueue() }

    // ── internals (executor thread only) ────────────────────────────────────

    /** The id events are reported under: the identified user, else the anon id. */
    fun appUserId(): String {
        store.get(KEY_USER_ID)?.let { return it }
        store.get(KEY_ANON_ID)?.let { return it }
        val fresh = freshAnonId()
        store.put(KEY_ANON_ID, fresh)
        return fresh
    }

    private fun attributeNow(originalTransactionId: String, productId: String?) {
        if (originalTransactionId.isEmpty()) {
            log.warn("attributePurchase called without a purchase token — ignored")
            return
        }
        val user = appUserId()
        val sent = sentTransactions()
        if (sent.optString(originalTransactionId) == user) {
            log.debug("txn $originalTransactionId already attributed to $user — skipped")
            return
        }
        sent.put(originalTransactionId, user)
        store.put(KEY_SENT_TXNS, sent.toString())
        send(
            Payloads.ATTRIBUTE_PATH,
            Payloads.attribute(user, device.bundleId, originalTransactionId, productId),
        )
    }

    private fun sentTransactions(): JSONObject = try {
        JSONObject(store.get(KEY_SENT_TXNS) ?: "{}")
    } catch (_: Throwable) {
        JSONObject()
    }

    private fun reattributeSentTransactions(userId: String) {
        val sent = sentTransactions()
        for (txn in sent.keys().asSequence().toList()) {
            if (sent.optString(txn) != userId) attributeNow(txn, null)
        }
    }

    private fun send(path: String, payload: JSONObject) {
        val body = payload.toString()
        if (deliver(path, body, MAX_ATTEMPTS)) {
            flushQueue()
        } else {
            queue.append(PendingRequest(path, body))
            log.info("queued $path for later delivery")
        }
    }

    private fun flushQueue() {
        var pending = queue.load()
        if (pending.isEmpty()) return
        log.debug("flushing ${pending.size} queued request(s)")
        while (pending.isNotEmpty()) {
            val item = pending.first()
            if (!deliver(item.path, item.body, 1)) break
            pending = pending.drop(1)
        }
        queue.save(pending)
    }

    /**
     * True when delivered — or permanently rejected (a request the server
     * will never accept is dropped, not retried forever).
     */
    private fun deliver(path: String, body: String, attempts: Int): Boolean {
        val url = options.baseUrl.trimEnd('/') + path
        val headers = mapOf(
            "Authorization" to "Bearer $apiKey",
            "Content-Type" to "application/json",
        )
        for (attempt in 0 until attempts) {
            try {
                when (val status = transport.post(url, body, headers)) {
                    in 200..299 -> return true
                    401 -> {
                        log.error("401 from $path — check your publishable key (pk_live_…)")
                        return true // never accepted; don't retry forever
                    }
                    429, in 500..599 -> log.warn("$status from $path — backing off")
                    else -> {
                        log.error("$status from $path — dropped")
                        return true
                    }
                }
            } catch (t: Throwable) {
                log.debug("network error on $path: ${t.message}")
            }
            if (attempt < attempts - 1) {
                try {
                    sleep(backoffMs(attempt))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
        }
        return false
    }

    /** Submits work to the executor; any escaped throwable is swallowed. */
    private fun run(work: () -> Unit) {
        try {
            executor.execute {
                try {
                    work()
                } catch (t: Throwable) {
                    log.error("swallowed: ${t.message}")
                }
            }
        } catch (t: Throwable) {
            log.error("swallowed: ${t.message}")
        }
    }

    private fun freshAnonId() = "\$anon_" + UUID.randomUUID().toString().lowercase()

    private companion object {
        const val KEY_USER_ID = "rh_user_id"
        const val KEY_ANON_ID = "rh_anon_id"
        const val KEY_SENT_TXNS = "rh_sent_txns"
        const val MAX_ATTEMPTS = 3
    }
}
