package com.revenuehog.android

import org.json.JSONObject

/**
 * Device context sent with identify. Nothing here is an identifier — no
 * advertising id, no fingerprinting. Just enough for a customer profile.
 */
data class DeviceInfo(
    val bundleId: String,
    val platform: String = "android",
    val osVersion: String? = null,
    val deviceModel: String? = null,
    val locale: String? = null,
)

/** Builds the JSON bodies for the two SDK endpoints. Null fields are omitted. */
internal object Payloads {
    const val IDENTIFY_PATH = "/api/sdk/v1/identify"
    const val ATTRIBUTE_PATH = "/api/sdk/v1/attribute"
    const val PAYWALL_PATH = "/api/sdk/v1/paywall"
    const val IMPRESSION_PATH = "/api/sdk/v1/paywall/impression"

    fun paywall(
        appUserId: String,
        bundleId: String,
        installId: String,
        entitlement: String,
        forceVariant: String? = null,
    ): JSONObject {
        val json = JSONObject()
            .put("appUserId", appUserId)
            .put("bundleId", bundleId)
            .put("installId", installId)
            .put("entitlement", entitlement)
        forceVariant?.let { json.put("forceVariant", it) }
        return json
    }

    fun impression(
        bundleId: String,
        installId: String,
        experimentId: String,
        renderedSkus: List<String>,
    ): JSONObject = JSONObject()
        .put("bundleId", bundleId)
        .put("installId", installId)
        .put("experimentId", experimentId)
        .put("renderedSkus", org.json.JSONArray(renderedSkus.take(50)))

    fun identify(
        appUserId: String,
        device: DeviceInfo,
        attributes: Map<String, String>? = null,
    ): JSONObject {
        val json = JSONObject()
            .put("appUserId", appUserId)
            .put("bundleId", device.bundleId)
            .put("platform", device.platform)
        device.osVersion?.let { json.put("osVersion", it) }
        device.deviceModel?.let { json.put("deviceModel", it) }
        device.locale?.let { json.put("locale", it) }
        if (attributes != null) {
            val attrs = JSONObject()
            for ((key, value) in attributes) attrs.put(key, value)
            json.put("attributes", attrs)
        }
        return json
    }

    fun attribute(
        appUserId: String,
        bundleId: String,
        originalTransactionId: String,
        productId: String? = null,
    ): JSONObject {
        val json = JSONObject()
            .put("appUserId", appUserId)
            .put("bundleId", bundleId)
            // Tells the server the id is a Play purchase token, so it links the
            // purchase to the Google Play app's subscription lineage.
            .put("platform", "android")
            .put("originalTransactionId", originalTransactionId)
        productId?.let { json.put("productId", it) }
        return json
    }
}
