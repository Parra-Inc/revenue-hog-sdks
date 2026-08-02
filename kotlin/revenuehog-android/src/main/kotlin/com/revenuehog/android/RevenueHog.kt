package com.revenuehog.android

import android.content.Context
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
                ),
                store = SharedPreferencesStore(prefs),
                executor = Executors.newSingleThreadExecutor { runnable ->
                    Thread(runnable, "revenuehog").apply { isDaemon = true }
                },
                logSink = { Log.d("RevenueHog", it) },
            )
            client = created
            created.flush()
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

    /** Retries anything sitting in the offline queue. */
    @JvmStatic
    fun flush() {
        withClient("flush") { it.flush() }
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
