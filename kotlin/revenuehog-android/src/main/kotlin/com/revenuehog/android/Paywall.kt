package com.revenuehog.android

import org.json.JSONObject

/**
 * One SKU in a server-decided paywall menu, in render order. [kind] is
 * `"subscription"`, `"iap"`, or `"unknown"` (compiled-in fallback entries,
 * and wire values newer than this SDK).
 */
data class PaywallSku(val productId: String, val kind: String)

/**
 * The answer to "which SKUs should this paywall offer": an ORDERED list.
 * Render in this order — under an experiment the order is part of what is
 * being tested. Never absent: on any failure it carries the compiled-in
 * fallback with [isFallback] true.
 */
data class Paywall(
    val entitlement: String,
    val skus: List<PaywallSku>,
    /** Present while an A/B experiment is serving this install. */
    val experimentId: String? = null,
    /** This install's variant, for the app's own analytics. */
    val variantKey: String? = null,
    val isFallback: Boolean,
) {
    /** The ordered product ids, ready for your billing product loader. */
    val productIds: List<String> get() = skus.map { it.productId }

    companion object {
        internal fun fallback(entitlement: String, productIds: List<String>): Paywall =
            Paywall(
                entitlement = entitlement,
                skus = productIds.map { PaywallSku(it, "unknown") },
                isFallback = true,
            )

        private val KNOWN_KINDS = setOf("subscription", "iap")

        /** Lenient wire decode: junk rows drop, unknown kinds pass through. */
        internal fun fromWire(json: JSONObject, requestedEntitlement: String): Paywall {
            val skus = mutableListOf<PaywallSku>()
            val rows = json.optJSONArray("skus")
            if (rows != null) {
                for (i in 0 until rows.length()) {
                    val row = rows.optJSONObject(i) ?: continue
                    val productId = row.optString("productId", "")
                    if (productId.isEmpty()) continue
                    val kind = row.optString("kind", "")
                    skus.add(PaywallSku(productId, if (kind in KNOWN_KINDS) kind else "unknown"))
                }
            }
            return Paywall(
                entitlement = json.optString("entitlement", requestedEntitlement)
                    .ifEmpty { requestedEntitlement },
                skus = skus,
                experimentId = json.optString("experimentId", "").ifEmpty { null },
                variantKey = json.optString("variantKey", "").ifEmpty { null },
                isFallback = skus.isEmpty(),
            )
        }
    }
}
