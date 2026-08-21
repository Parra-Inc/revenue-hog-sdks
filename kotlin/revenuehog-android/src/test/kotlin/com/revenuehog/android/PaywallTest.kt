package com.revenuehog.android

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PaywallTest {
    private val experimentJson = JSONObject()
        .put("entitlement", "pro")
        .put(
            "skus",
            org.json.JSONArray()
                .put(JSONObject().put("productId", "pro_annual").put("kind", "subscription"))
                .put(JSONObject().put("productId", "pro_monthly").put("kind", "subscription"))
                .put(JSONObject().put("productId", "credits_500").put("kind", "iap")),
        )
        .put("experimentId", "exp_1")
        .put("variantKey", "b")
        .put("ttlSeconds", 900)
        .toString()

    private fun paywallRequests(transport: FakeTransport) =
        transport.requests.filter { it.url.endsWith(Payloads.PAYWALL_PATH) }

    private fun fetch(
        client: HogClient,
        entitlement: String,
        fallback: List<String>,
        forceVariant: String? = null,
    ): Paywall {
        var result: Paywall? = null
        client.paywall(entitlement, fallback, forceVariant) { result = it }
        return requireNotNull(result) { "callback did not run synchronously" }
    }

    @Test
    fun `sends the installId and decodes the ordered menu`() {
        val transport = FakeTransport().apply { bodies.add(experimentJson) }
        val client = TestSupport.makeClient(transport)

        val paywall = fetch(client, "pro", listOf("fb_monthly"))

        assertEquals(listOf("pro_annual", "pro_monthly", "credits_500"), paywall.productIds)
        assertEquals(listOf("subscription", "subscription", "iap"), paywall.skus.map { it.kind })
        assertEquals("exp_1", paywall.experimentId)
        assertEquals("b", paywall.variantKey)
        assertFalse(paywall.isFallback)

        val request = paywallRequests(transport).first().json
        assertEquals("pro", request.optString("entitlement"))
        assertEquals("com.example.app", request.optString("bundleId"))
        assertTrue(request.optString("installId").isNotEmpty())
        assertTrue(request.optString("appUserId").startsWith("\$anon_"))
    }

    @Test
    fun `persists the installId across clients and reset`() {
        val store = MemoryStore()
        val transport = FakeTransport().apply {
            bodies.add(experimentJson)
            bodies.add(experimentJson)
        }
        val first = TestSupport.makeClient(transport, store)
        fetch(first, "pro", emptyList())
        first.reset()

        val second = TestSupport.makeClient(transport, store)
        fetch(second, "pro", emptyList())

        val ids = paywallRequests(transport).map { it.json.optString("installId") }
        assertEquals(2, ids.size)
        assertEquals(ids[0], ids[1])
    }

    @Test
    fun `serves a fresh cache without touching the network`() {
        val transport = FakeTransport().apply { bodies.add(experimentJson) }
        val client = TestSupport.makeClient(transport)

        val first = fetch(client, "pro", emptyList())
        val second = fetch(client, "pro", emptyList())

        assertEquals(first, second)
        assertEquals(1, paywallRequests(transport).size)
    }

    @Test
    fun `an empty answer serves the compiled-in fallback`() {
        val transport = FakeTransport().apply {
            bodies.add("""{"entitlement":"pro","skus":[],"ttlSeconds":3600}""")
        }
        val client = TestSupport.makeClient(transport)

        val paywall = fetch(client, "pro", listOf("fb_monthly", "fb_annual"))

        assertTrue(paywall.isFallback)
        assertEquals(listOf("fb_monthly", "fb_annual"), paywall.productIds)
        assertEquals(listOf("unknown", "unknown"), paywall.skus.map { it.kind })
        assertNull(paywall.experimentId)
    }

    @Test
    fun `a network failure serves stale cache however old`() {
        val store = MemoryStore()
        val transport = FakeTransport(TestSupport.NETWORK_ERROR)
        val client = TestSupport.makeClient(transport, store)
        val user = client.appUserId()
        store.put(
            "rh_paywall_cache",
            JSONObject()
                .put(
                    "pro",
                    JSONObject(experimentJson)
                        .put("fetchedAt", System.currentTimeMillis() - 7_200_000)
                        .put("ttlSeconds", 60)
                        .put("appUserId", user),
                )
                .toString(),
        )

        val paywall = fetch(client, "pro", listOf("fb"))

        assertEquals(listOf("pro_annual", "pro_monthly", "credits_500"), paywall.productIds)
        assertEquals("b", paywall.variantKey)
        assertFalse(paywall.isFallback)
    }

    @Test
    fun `a network failure with no cache serves the fallback`() {
        val transport = FakeTransport(TestSupport.NETWORK_ERROR)
        val client = TestSupport.makeClient(transport)

        val paywall = fetch(client, "pro", listOf("fb_monthly"))

        assertTrue(paywall.isFallback)
        assertEquals(listOf("fb_monthly"), paywall.productIds)
    }

    @Test
    fun `an identity change invalidates the cache`() {
        val transport = FakeTransport().apply {
            bodies.add(experimentJson)
            bodies.add(experimentJson)
        }
        val client = TestSupport.makeClient(transport)

        fetch(client, "pro", emptyList())
        client.identify("user_42")
        fetch(client, "pro", emptyList())

        val requests = paywallRequests(transport)
        assertEquals(2, requests.size)
        assertEquals("user_42", requests.last().json.optString("appUserId"))
    }

    @Test
    fun `forceVariant bypasses and never poisons the cache`() {
        val forced = JSONObject()
            .put("entitlement", "pro")
            .put(
                "skus",
                org.json.JSONArray()
                    .put(JSONObject().put("productId", "forced_sku").put("kind", "subscription")),
            )
            .put("experimentId", "exp_1")
            .put("variantKey", "c")
            .put("forced", true)
            .put("ttlSeconds", 900)
            .toString()
        val transport = FakeTransport().apply {
            bodies.add(forced)
            bodies.add(experimentJson)
        }
        val client = TestSupport.makeClient(transport)

        val preview = fetch(client, "pro", emptyList(), forceVariant = "c")
        val real = fetch(client, "pro", emptyList())

        assertEquals(listOf("forced_sku"), preview.productIds)
        assertEquals(listOf("pro_annual", "pro_monthly", "credits_500"), real.productIds)
        val requests = paywallRequests(transport)
        assertEquals(2, requests.size)
        assertEquals("c", requests.first().json.optString("forceVariant"))
        assertFalse(requests.last().json.has("forceVariant"))
    }

    @Test
    fun `paywallShown posts the impression only under an experiment`() {
        val transport = FakeTransport().apply { bodies.add(experimentJson) }
        val client = TestSupport.makeClient(transport)

        val paywall = fetch(client, "pro", emptyList())
        client.paywallShown(paywall, listOf("pro_annual", "pro_monthly"))

        val impressions = transport.requests.filter { it.url.endsWith(Payloads.IMPRESSION_PATH) }
        assertEquals(1, impressions.size)
        assertEquals("exp_1", impressions.first().json.optString("experimentId"))
        assertEquals(
            listOf("pro_annual", "pro_monthly"),
            impressions.first().json.getJSONArray("renderedSkus").let { rows ->
                (0 until rows.length()).map { rows.getString(it) }
            },
        )
        assertEquals(
            paywallRequests(transport).first().json.optString("installId"),
            impressions.first().json.optString("installId"),
        )

        client.paywallShown(Paywall.fallback("pro", listOf("fb")), listOf("fb"))
        assertEquals(
            1,
            transport.requests.count { it.url.endsWith(Payloads.IMPRESSION_PATH) },
        )
    }

    @Test
    fun `unknown kinds decode as unknown`() {
        val transport = FakeTransport().apply {
            bodies.add(
                """{"entitlement":"pro","skus":[{"productId":"x","kind":"bundle"}],"ttlSeconds":900}""",
            )
        }
        val client = TestSupport.makeClient(transport)

        val paywall = fetch(client, "pro", emptyList())

        assertEquals(listOf("unknown"), paywall.skus.map { it.kind })
        assertFalse(paywall.isFallback)
    }
}
