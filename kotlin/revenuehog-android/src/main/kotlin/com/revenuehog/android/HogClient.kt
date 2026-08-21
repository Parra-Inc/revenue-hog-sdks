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
        if (store.get(KEY_USER_ID) != trimmed) {
            // The appUserId sent on paywall fetches is how purchases join
            // experiment results; a cached answer from the old identity
            // would leave the new one unlinked.
            store.put(KEY_PAYWALL_CACHE, null)
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
        store.put(KEY_PAYWALL_CACHE, null)
        // rh_install_id survives on purpose: it keys paywall experiment
        // assignment to the DEVICE, not to a user.
        store.put(KEY_ANON_ID, freshAnonId())
        queue.clear()
        log.info("reset — new anonymous id issued")
    }

    fun flush() = run { flushQueue() }

    /**
     * Which SKUs this install's paywall should offer, as an ORDERED list
     * the dashboard controls (and can A/B test). Never fails: fresh cache,
     * then one short network fetch, then stale cache, then the compiled-in
     * [fallback]. [onResult] runs on the SDK's background thread — hop to
     * the main thread before touching views.
     */
    fun paywall(
        entitlement: String,
        fallback: List<String>,
        forceVariant: String? = null,
        onResult: (Paywall) -> Unit,
    ) = run {
        val result = try {
            paywallNow(entitlement.trim(), fallback, forceVariant)
        } catch (t: Throwable) {
            log.error("paywall failed: ${t.message}")
            Paywall.fallback(entitlement, fallback)
        }
        try {
            onResult(result)
        } catch (t: Throwable) {
            log.error("paywall onResult threw: ${t.message}")
        }
    }

    /**
     * Reports that a paywall actually APPEARED, with the product ids that
     * really rendered. Fetching assigns; impressions expose. No-op outside
     * an experiment; best-effort and never queued (a replayed impression
     * would count an exposure that may never have happened).
     */
    fun paywallShown(paywall: Paywall, rendered: List<String>) = run {
        val experimentId = paywall.experimentId ?: return@run
        deliver(
            Payloads.IMPRESSION_PATH,
            Payloads.impression(device.bundleId, installId(), experimentId, rendered).toString(),
            attempts = 2,
        )
    }

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

    // ── paywall internals ───────────────────────────────────────────────────

    private fun paywallNow(
        entitlement: String,
        fallback: List<String>,
        forceVariant: String?,
    ): Paywall {
        if (entitlement.isEmpty()) {
            log.warn("paywall called with an empty entitlement — serving the fallback")
            return Paywall.fallback(entitlement, fallback)
        }
        val user = appUserId()
        val cache = paywallCache()
        val cached = cache.optJSONObject(entitlement)
        val fresh = cached != null &&
            cached.optString("appUserId") == user &&
            System.currentTimeMillis() - cached.optLong("fetchedAt") <
            cached.optLong("ttlSeconds", 3600) * 1000
        if (fresh && forceVariant == null) {
            log.debug("paywall($entitlement) served from cache")
            return resolvePaywall(Paywall.fromWire(cached!!, entitlement), fallback)
        }

        val body = Payloads.paywall(user, device.bundleId, installId(), entitlement, forceVariant)
        val answer = fetchPaywall(body.toString())
        if (answer != null) {
            val paywall = Paywall.fromWire(answer, entitlement)
            // Forced previews are QA-only: never cached, never the real menu.
            if (forceVariant == null) {
                answer.put("fetchedAt", System.currentTimeMillis())
                answer.put(
                    "ttlSeconds",
                    answer.optLong("ttlSeconds", 3600).coerceIn(60, 86_400),
                )
                answer.put("appUserId", user)
                cache.put(entitlement, answer)
                store.put(KEY_PAYWALL_CACHE, cache.toString())
            }
            return resolvePaywall(paywall, fallback)
        }

        // Network failure: stale beats empty, however old.
        if (cached != null) {
            log.info("paywall($entitlement) network failed — serving stale cache")
            return resolvePaywall(Paywall.fromWire(cached, entitlement), fallback)
        }
        log.info("paywall($entitlement) unreachable with no cache — serving the fallback")
        return Paywall.fallback(entitlement, fallback)
    }

    /** A server answer with SKUs passes through; an empty one becomes the fallback. */
    private fun resolvePaywall(paywall: Paywall, fallback: List<String>): Paywall =
        if (paywall.skus.isNotEmpty()) paywall else Paywall.fallback(paywall.entitlement, fallback)

    /**
     * One UUID per install, persisted so paywall experiment assignment
     * sticks to this device. SharedPreferences survives logout but not
     * reinstall — the documented degraded stickiness vs the iOS Keychain.
     */
    private fun installId(): String {
        store.get(KEY_INSTALL_ID)?.let { return it }
        val fresh = UUID.randomUUID().toString().uppercase()
        store.put(KEY_INSTALL_ID, fresh)
        return fresh
    }

    private fun paywallCache(): JSONObject = try {
        JSONObject(store.get(KEY_PAYWALL_CACHE) ?: "{}")
    } catch (_: Throwable) {
        JSONObject()
    }

    /** One attempt against a short deadline; null on any failure. */
    private fun fetchPaywall(body: String): JSONObject? = try {
        val url = options.baseUrl.trimEnd('/') + Payloads.PAYWALL_PATH
        val headers = mapOf("Content-Type" to "application/json")
        val response = transport.postForBody(url, body, headers, PAYWALL_TIMEOUT_MS)
        if (response.status in 200..299) JSONObject(response.body) else {
            log.warn("${response.status} from ${Payloads.PAYWALL_PATH}")
            null
        }
    } catch (t: Throwable) {
        log.debug("network error on ${Payloads.PAYWALL_PATH}: ${t.message}")
        null
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
        val headers = mapOf("Content-Type" to "application/json")
        for (attempt in 0 until attempts) {
            try {
                when (val status = transport.post(url, body, headers)) {
                    in 200..299 -> return true
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
        const val KEY_INSTALL_ID = "rh_install_id"
        const val KEY_PAYWALL_CACHE = "rh_paywall_cache"
        const val MAX_ATTEMPTS = 3
        const val PAYWALL_TIMEOUT_MS = 2_500
    }
}
