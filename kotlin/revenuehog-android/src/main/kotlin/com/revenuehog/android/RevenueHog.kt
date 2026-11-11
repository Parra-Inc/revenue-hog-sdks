package com.revenuehog.android

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.content.SharedPreferences
import android.os.Build
import android.util.Log
import java.lang.reflect.Proxy
import java.util.Locale
import java.util.concurrent.Executors

/**
 * RevenueHog user-level attribution. One required line, in
 * `Application.onCreate()`:
 *
 * ```kotlin
 * RevenueHog.configure(this)
 * ```
 *
 * No API key: requests are unauthenticated and the server labels the
 * resulting identity data unverified until attestation support (Play
 * Integrity) lands.
 *
 * Note: RevenueHog's revenue tracking works entirely server-side without
 * this SDK (Apple App Store ingestion today). The Android SDK exists for
 * identity parity across platforms and future Play support — [identify] and
 * [setAttributes] enrich customer profiles now; [attributePurchase] stores
 * the purchase→user mapping server-side for when Play ingestion ships.
 */
object RevenueHog {
    @Volatile
    private var client: HogClient? = null

    @Volatile
    private var autoTrigger = true

    /** Sets up the SDK. Call once, as early as possible. Never throws. */
    @JvmStatic
    @JvmOverloads
    fun configure(context: Context, options: Options = Options()) {
        try {
            val app = context.applicationContext
            val prefs = app.getSharedPreferences("dev.revenuehog.sdk", Context.MODE_PRIVATE)
            val created = HogClient(
                options = options,
                device = DeviceInfo(
                    bundleId = app.packageName ?: "unknown",
                    platform = "android",
                    osVersion = Build.VERSION.RELEASE,
                    deviceModel = Build.MODEL,
                    locale = Locale.getDefault().toString(),
                    appVersion = runCatching {
                        @Suppress("DEPRECATION")
                        app.packageManager.getPackageInfo(app.packageName, 0).versionName
                    }.getOrNull(),
                ),
                store = SharedPreferencesStore(prefs),
                executor = Executors.newSingleThreadExecutor { runnable ->
                    Thread(runnable, "revenuehog").apply { isDaemon = true }
                },
                logSink = { Log.d("RevenueHog", it) },
            )
            client = created
            autoTrigger = options.enableChurnSurveyAutoTrigger
            created.flush()
            created.sendDailyOpen()
        } catch (t: Throwable) {
            Log.d("RevenueHog", "configure failed: ${t.message}")
        }
    }

    /**
     * Tells RevenueHog who this user is. Anything reported before this call
     * (under the persisted anonymous id) is re-attributed to [userId].
     */
    @JvmStatic
    fun identify(userId: String) {
        withClient("identify") { it.identify(userId) }
    }

    /** Attaches flat string key/values to the current user's profile. */
    @JvmStatic
    fun setAttributes(attributes: Map<String, String>) {
        withClient("setAttributes") { it.setAttributes(attributes) }
    }

    /**
     * Links a purchase to the current user. Pass the Play Billing
     * `purchaseToken`. Apple ingestion is live today; Play mappings are
     * stored server-side and light up when Play ingestion ships.
     */
    @JvmStatic
    @JvmOverloads
    fun attributePurchase(purchaseToken: String, productId: String? = null) {
        withClient("attributePurchase") { it.attributePurchase(purchaseToken, productId) }
    }

    /** Forgets the current user (call on logout); issues a fresh anonymous id. */
    @JvmStatic
    fun reset() {
        withClient("reset") { it.reset() }
    }

    /** Sends buffered events and retries anything sitting in the offline queue. */
    @JvmStatic
    fun flush() {
        withClient("flush") { it.flush() }
    }

    /**
     * Records a funnel milestone such as `onboarding_completed`. Names are
     * snake_case, start with a letter, at most 48 characters, and may not
     * start with `rh_` (invalid names are dropped with a warning).
     * [properties] is a small flat map of strings, numbers and booleans (2 KB
     * of JSON at most). Events are persisted and sent in batches of up to
     * 50: when 20 are waiting, about 10 seconds after the first, on [flush],
     * and on the next launch. The reserved name `onboarding_step` with
     * `step` and `index` feeds the dashboard's onboarding funnel.
     */
    @JvmStatic
    @JvmOverloads
    fun track(name: String, properties: Map<String, Any?>? = null) {
        withClient("track") { it.track(name, properties) }
    }

    /**
     * Sends in-app feedback (bug, idea, question or praise) attributed to the
     * current user, with device context added to `metadata`. [message] is
     * required (max 5000 characters); [rating] is 1 to 5. [onResult] runs on
     * the SDK's background thread with [FeedbackResult.Sent],
     * [FeedbackResult.Queued] (offline; persisted and delivered later) or
     * [FeedbackResult.Rejected].
     */
    @JvmStatic
    @JvmOverloads
    fun sendFeedback(
        kind: FeedbackKind,
        message: String,
        rating: Int? = null,
        data: Map<String, Any?>? = null,
        metadata: Map<String, Any?>? = null,
        onResult: ((FeedbackResult) -> Unit)? = null,
    ) {
        val current = client
        if (current == null) {
            Log.d("RevenueHog", "sendFeedback called before configure")
            try {
                onResult?.invoke(FeedbackResult.Rejected("not configured"))
            } catch (_: Throwable) {
            }
            return
        }
        try {
            current.sendFeedback(kind, message, rating, data, metadata, onResult)
        } catch (t: Throwable) {
            Log.d("RevenueHog", "swallowed: ${t.message}")
        }
    }

    /**
     * Which SKUs this install's paywall should offer for [entitlement], as
     * an ORDERED list the RevenueHog dashboard controls (and can A/B test)
     * without an app update. Never fails: fresh cache, then a short network
     * fetch, then stale cache, then your compiled-in [fallback] list — the
     * paywall is the money path and can never come back empty.
     *
     * Call it when the paywall is about to show, render the SKUs in the
     * returned order, and call [paywallShown] once it is on screen.
     * [onResult] runs on the SDK's background thread — hop to the main
     * thread before touching views. [forceVariant] is QA-only: the server
     * honors it for non-production traffic and records nothing.
     */
    @JvmStatic
    @JvmOverloads
    fun paywall(
        entitlement: String,
        fallback: List<String>,
        forceVariant: String? = null,
        onResult: (Paywall) -> Unit,
    ) {
        val current = client
        if (current == null) {
            Log.d("RevenueHog", "paywall called before configure — serving the compiled-in fallback")
            try {
                onResult(Paywall.fallback(entitlement, fallback))
            } catch (_: Throwable) {
            }
            return
        }
        try {
            current.paywall(entitlement, fallback, forceVariant, onResult)
        } catch (t: Throwable) {
            Log.d("RevenueHog", "swallowed: ${t.message}")
            try {
                onResult(Paywall.fallback(entitlement, fallback))
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * Reports that a paywall actually APPEARED, with the product ids that
     * really rendered (after billing product loading). Keeps prefetched-
     * but-never-shown paywalls out of experiment denominators. No-op
     * outside an experiment.
     */
    @JvmStatic
    fun paywallShown(paywall: Paywall, rendered: List<String>) {
        withClient("paywallShown") { it.paywallShown(paywall, rendered) }
    }

    /**
     * Shows the churn survey now, over [activity]. Call it right before
     * opening subscription management. Respects the dashboard switch,
     * sampling and the once-per-90-days cap; [onResult] (main thread) gets
     * [ChurnSurveyResult.NotShown] when any of them says no. The answer, or
     * the skip, is recorded automatically.
     */
    @JvmStatic
    @JvmOverloads
    fun presentChurnSurvey(
        activity: Activity,
        productId: String? = null,
        onResult: ((ChurnSurveyResult) -> Unit)? = null,
    ) {
        val current = client
        if (current == null) {
            Log.d("RevenueHog", "presentChurnSurvey called before configure")
            onResult?.invoke(ChurnSurveyResult.NotShown)
            return
        }
        present(current, activity, automatic = false, productId = productId, onResult = onResult)
    }

    /**
     * Auto trigger: pass the Play Billing `Purchase` objects from
     * `queryPurchasesAsync` (read reflectively, no Billing dependency). The
     * first time a subscription shows `isAutoRenewing == false`, the survey
     * appears once for that cancellation. A purchase that renews again
     * resets, so a later cancel asks again.
     */
    @JvmStatic
    fun checkPurchasesForChurn(activity: Activity, purchases: List<*>) {
        val current = client ?: return
        if (!autoTrigger) return
        try {
            val renewals = purchases.mapNotNull { p ->
                if (p == null) return@mapNotNull null
                val token = runCatching { p.javaClass.getMethod("getPurchaseToken").invoke(p) as? String }.getOrNull()
                val renewing = runCatching { p.javaClass.getMethod("isAutoRenewing").invoke(p) as? Boolean }.getOrNull()
                val product = runCatching {
                    (p.javaClass.getMethod("getProducts").invoke(p) as? List<*>)?.firstOrNull() as? String
                }.getOrNull()
                if (token == null || renewing == null) null else Triple(token, renewing, product)
            }
            autoRenewChanged(activity, current, renewals)
        } catch (t: Throwable) {
            Log.d("RevenueHog", "swallowed: ${t.message}")
        }
    }

    /**
     * Same as [checkPurchasesForChurn] for apps that track renewal state
     * themselves: report one subscription's auto-renew state.
     */
    @JvmStatic
    @JvmOverloads
    fun autoRenewChanged(activity: Activity, purchaseToken: String, willAutoRenew: Boolean, productId: String? = null) {
        val current = client ?: return
        if (!autoTrigger) return
        autoRenewChanged(activity, current, listOf(Triple(purchaseToken, willAutoRenew, productId)))
    }

    private fun autoRenewChanged(activity: Activity, current: HogClient, renewals: List<Triple<String, Boolean, String?>>) {
        current.claimNewlyCancelled(renewals.map { it.first to it.second }) { fresh ->
            if (fresh == null) return@claimNewlyCancelled
            val productId = renewals.firstOrNull { it.first == fresh }?.third
            present(current, activity, automatic = true, productId = productId) { result ->
                if (result != ChurnSurveyResult.NotShown) current.markChurnHandled(fresh)
            }
        }
    }

    private fun present(
        current: HogClient,
        activity: Activity,
        automatic: Boolean,
        productId: String?,
        onResult: ((ChurnSurveyResult) -> Unit)?,
    ) {
        val main = Handler(Looper.getMainLooper())
        fun deliver(result: ChurnSurveyResult) {
            try {
                onResult?.invoke(result)
            } catch (_: Throwable) {
            }
        }
        current.churnSurvey(automatic) { survey ->
            main.post {
                if (survey == null || activity.isFinishing) {
                    deliver(ChurnSurveyResult.NotShown)
                    return@post
                }
                try {
                    current.churnSurveyShown()
                    ChurnSurveyDialog.show(activity, survey) { result ->
                        current.submitChurnSurvey(survey, result, productId)
                        deliver(result)
                    }
                } catch (t: Throwable) {
                    Log.d("RevenueHog", "swallowed: ${t.message}")
                    deliver(ChurnSurveyResult.NotShown)
                }
            }
        }
    }

    /**
     * Optional Play Billing helper. If the host app ships
     * `com.android.billingclient` (the SDK itself does NOT depend on it),
     * this returns a `PurchasesUpdatedListener` that forwards every purchase
     * to [attributePurchase] and then to your [delegate]:
     *
     * ```kotlin
     * val listener = RevenueHog.billingListener(myListener) as PurchasesUpdatedListener
     * BillingClient.newBuilder(context).setListener(listener) …
     * ```
     *
     * Built with reflection so this SDK stays dependency-free. If Play
     * Billing isn't on the classpath, returns [delegate] unchanged.
     */
    @JvmStatic
    @JvmOverloads
    fun billingListener(delegate: Any? = null): Any? = try {
        val listenerInterface =
            Class.forName("com.android.billingclient.api.PurchasesUpdatedListener")
        Proxy.newProxyInstance(
            listenerInterface.classLoader,
            arrayOf(listenerInterface),
        ) { proxy, method, args ->
            when (method.name) {
                "onPurchasesUpdated" -> {
                    try {
                        (args?.getOrNull(1) as? List<*>)?.forEach { attributeReflectively(it) }
                    } catch (_: Throwable) {
                        // never break the host app's purchase flow
                    }
                    if (delegate != null) {
                        try {
                            method.invoke(delegate, *(args ?: emptyArray()))
                        } catch (_: Throwable) {
                        }
                    }
                    null
                }
                "hashCode" -> System.identityHashCode(proxy)
                "equals" -> proxy === args?.getOrNull(0)
                "toString" -> "RevenueHog.billingListener"
                else -> null
            }
        }
    } catch (_: Throwable) {
        // Play Billing not on the classpath — hand back the delegate untouched
        delegate
    }

    private fun attributeReflectively(purchase: Any?) {
        if (purchase == null) return
        try {
            val token = purchase.javaClass.getMethod("getPurchaseToken")
                .invoke(purchase) as? String ?: return
            val productId = runCatching {
                (purchase.javaClass.getMethod("getProducts")
                    .invoke(purchase) as? List<*>)?.firstOrNull() as? String
            }.getOrNull()
            attributePurchase(token, productId)
        } catch (_: Throwable) {
        }
    }

    private inline fun withClient(name: String, work: (HogClient) -> Unit) {
        val current = client
        if (current == null) {
            Log.d("RevenueHog", "$name called before configure — call RevenueHog.configure(context) first")
            return
        }
        try {
            work(current)
        } catch (t: Throwable) {
            Log.d("RevenueHog", "swallowed: ${t.message}")
        }
    }
}

internal class SharedPreferencesStore(
    private val prefs: SharedPreferences,
) : KeyValueStore {
    override fun get(key: String): String? = try {
        prefs.getString(key, null)
    } catch (_: Throwable) {
        null
    }

    override fun put(key: String, value: String?) {
        try {
            prefs.edit().apply {
                if (value == null) remove(key) else putString(key, value)
            }.apply()
        } catch (_: Throwable) {
        }
    }
}
