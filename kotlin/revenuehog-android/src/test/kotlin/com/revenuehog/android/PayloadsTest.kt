package com.revenuehog.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class PayloadsTest {
    private val device = DeviceInfo(
        bundleId = "com.example.app",
        platform = "android",
        osVersion = "14",
        deviceModel = "Pixel 8",
        locale = "en_US",
    )

    @Test
    fun `identify includes all fields`() {
        val json = Payloads.identify("user_1", device, mapOf("plan" to "pro"))

        assertEquals("user_1", json.getString("appUserId"))
        assertEquals("com.example.app", json.getString("bundleId"))
        assertEquals("android", json.getString("platform"))
        assertEquals("14", json.getString("osVersion"))
        assertEquals("Pixel 8", json.getString("deviceModel"))
        assertEquals("en_US", json.getString("locale"))
        assertEquals("pro", json.getJSONObject("attributes").getString("plan"))
    }

    @Test
    fun `identify omits null fields`() {
        val json = Payloads.identify("u", DeviceInfo(bundleId = "b"))

        assertEquals(setOf("appUserId", "bundleId", "platform"), json.keySet())
    }

    @Test
    fun `attribute includes purchase token as originalTransactionId`() {
        val json = Payloads.attribute("user_1", "com.example.app", "gpa.1234-5678", "pro_monthly")

        assertEquals("user_1", json.getString("appUserId"))
        assertEquals("com.example.app", json.getString("bundleId"))
        assertEquals("gpa.1234-5678", json.getString("originalTransactionId"))
        assertEquals("pro_monthly", json.getString("productId"))
    }

    @Test
    fun `attribute omits null productId`() {
        val json = Payloads.attribute("u", "b", "txn")

        assertFalse(json.has("productId"))
    }
}
