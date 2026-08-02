package com.revenuehog.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class HogClientTest {
    @Test
    fun `identify posts the full payload with no Authorization header`() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)

        client.identify("user_42")

        val request = transport.requests.first()
        assertEquals("https://example.test/api/sdk/v1/identify", request.url)
        assertNull(request.headers["Authorization"])
        assertEquals("application/json", request.headers["Content-Type"])
        assertEquals("user_42", request.json.getString("appUserId"))
        assertEquals("com.example.app", request.json.getString("bundleId"))
        assertEquals("android", request.json.getString("platform"))
    }

    @Test
    fun `attribute before identify uses a persisted anonymous id`() {
        val store = MemoryStore()
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport, store)

        client.attributePurchase("gpa.token-1", "pro_monthly")

        val request = transport.requests.first()
        assertEquals("https://example.test/api/sdk/v1/attribute", request.url)
        val anonId = request.json.getString("appUserId")
        assertTrue(anonId.startsWith("\$anon_"))

        // "second launch" with the same store keeps the same anon id
        val second = TestSupport.makeClient(FakeTransport(), store)
        assertEquals(anonId, second.appUserId())
    }

    @Test
    fun `identify re-attributes transactions reported anonymously`() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)

        client.attributePurchase("gpa.token-1", "pro_monthly")
        client.identify("user_42")

        val attributes = transport.requests
            .filter { it.url.endsWith("/attribute") }
            .map { it.json.getString("appUserId") }
        assertEquals(2, attributes.size)
        assertTrue(attributes[0].startsWith("\$anon_"))
        assertEquals("user_42", attributes[1])
    }

    @Test
    fun `duplicate attribution for the same user is skipped`() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)

        client.attributePurchase("gpa.token-1")
        client.attributePurchase("gpa.token-1")

        assertEquals(1, transport.requests.size)
    }

    @Test
    fun `rate-limited request is queued then flushed when healthy`() {
        val store = MemoryStore()
        val transport = FakeTransport(429, 429, 429)
        val client = TestSupport.makeClient(transport, store)

        client.setAttributes(mapOf("plan" to "pro"))
        assertEquals(1, RequestQueue(store).load().size)

        client.flush() // script empty → 200s
        assertEquals(0, RequestQueue(store).load().size)
        assertEquals(4, transport.requests.size)
        assertEquals(
            "pro",
            transport.requests.last().json.getJSONObject("attributes").getString("plan"),
        )
    }

    @Test
    fun `network errors retry up to three times then queue`() {
        val store = MemoryStore()
        val transport = FakeTransport(
            TestSupport.NETWORK_ERROR,
            TestSupport.NETWORK_ERROR,
            TestSupport.NETWORK_ERROR,
        )
        val client = TestSupport.makeClient(transport, store)

        client.setAttributes(mapOf("a" to "b"))

        assertEquals(3, transport.requests.size)
        assertEquals(1, RequestQueue(store).load().size)
    }

    @Test
    fun `401 is dropped without retrying or queueing`() {
        val store = MemoryStore()
        val transport = FakeTransport(401)
        val client = TestSupport.makeClient(transport, store)

        client.setAttributes(mapOf("a" to "b"))

        assertEquals(1, transport.requests.size)
        assertEquals(0, RequestQueue(store).load().size)
    }

    @Test
    fun `reset issues a fresh anonymous id and clears identity`() {
        val store = MemoryStore()
        val client = TestSupport.makeClient(FakeTransport(), store)

        client.identify("user_42")
        val before = client.appUserId()
        client.reset()
        val after = client.appUserId()

        assertEquals("user_42", before)
        assertTrue(after.startsWith("\$anon_"))
        assertNotEquals(before, after)
        assertNull(store.get("rh_user_id"))
    }

    @Test
    fun `blank userId is ignored`() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)

        client.identify("   ")

        assertEquals(0, transport.requests.size)
    }
}
