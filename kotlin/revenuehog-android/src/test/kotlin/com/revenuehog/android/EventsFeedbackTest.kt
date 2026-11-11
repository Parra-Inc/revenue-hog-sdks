package com.revenuehog.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EventsFeedbackTest {
    private fun FakeTransport.at(path: String) = requests.filter { it.url.endsWith(path) }

    @Test
    fun `track buffers until flush then sends one batch`() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)

        client.track("onboarding_step", mapOf("step" to "welcome", "index" to 0, "skipped" to false))
        client.track("paywall_viewed")
        assertTrue(transport.at("/api/sdk/v1/events").isEmpty())

        client.flush()
        val sent = transport.at("/api/sdk/v1/events")
        assertEquals(1, sent.size)
        val body = sent[0].json
        assertEquals("com.example.app", body.getString("bundleId"))
        assertEquals("android", body.getString("platform"))
        val events = body.getJSONArray("events")
        assertEquals(2, events.length())
        val first = events.getJSONObject(0)
        assertEquals("onboarding_step", first.getString("name"))
        assertEquals("welcome", first.getJSONObject("properties").getString("step"))
        assertEquals(0, first.getJSONObject("properties").getInt("index"))
        assertTrue(first.getString("appUserId").startsWith("\$anon_"))
        assertTrue(first.getLong("at") > 0)
        assertTrue(!events.getJSONObject(1).has("properties"))
    }

    @Test
    fun `invalid event names are dropped`() {
        for (bad in listOf("", "Signup", "1st", "rh_x", "a-b", "a".repeat(49))) {
            assertNull(EventRules.validName(bad))
        }
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)
        client.track("Bad Name")
        client.flush()
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `twenty events send automatically and batches cap at fifty`() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)
        repeat(20) { client.track("tap") }
        assertEquals(1, transport.at("/events").size)

        val store = MemoryStore()
        val events = org.json.JSONArray()
        repeat(120) { events.put(org.json.JSONObject().put("name", "tap").put("at", it).put("appUserId", "u")) }
        store.put("rh_event_buffer", events.toString())
        val t2 = FakeTransport()
        TestSupport.makeClient(t2, store).flush()
        assertEquals(listOf(50, 50, 20), t2.at("/events").map { it.json.getJSONArray("events").length() })
    }

    @Test
    fun `offline batch is queued and replayed`() {
        val store = MemoryStore()
        val net = TestSupport.NETWORK_ERROR
        val transport = FakeTransport(net, net, net, net)
        val client = TestSupport.makeClient(transport, store)
        client.track("tap")
        client.flush()
        assertEquals(listOf("/api/sdk/v1/events"), RequestQueue(store).load().map { it.path })
        client.flush()
        assertTrue(RequestQueue(store).load().isEmpty())
    }

    @Test
    fun `the timer flushes a lone event`() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport, eventFlushDelayMs = 10)
        client.track("tap")
        assertEquals(1, transport.at("/events").size)
    }

    @Test
    fun `feedback sends the full payload and returns the server id`() {
        val transport = FakeTransport()
        transport.bodies.add("""{"ok":true,"id":"fb_1"}""")
        val client = TestSupport.makeClient(transport)
        client.identify("user_42")
        var result: FeedbackResult? = null

        client.sendFeedback(
            FeedbackKind.BUG, "  It crashed  ", 2,
            mapOf("screen" to "settings", "steps" to listOf(1, 2)), mapOf("build" to 42),
        ) { result = it }

        assertEquals(FeedbackResult.Sent("fb_1"), result)
        val body = transport.at("/api/sdk/v1/feedback").single().json
        assertEquals("bug", body.getString("kind"))
        assertEquals("It crashed", body.getString("message"))
        assertEquals(2, body.getInt("rating"))
        assertEquals("user_42", body.getString("appUserId"))
        assertEquals("com.example.app", body.getString("bundleId"))
        assertEquals("android", body.getString("platform"))
        assertEquals("settings", body.getJSONObject("data").getString("screen"))
        assertEquals(2, body.getJSONObject("data").getJSONArray("steps").length())
        val meta = body.getJSONObject("metadata")
        assertEquals("14", meta.getString("osVersion"))
        assertEquals("2.1.0", meta.getString("appVersion"))
        assertEquals(42, meta.getInt("build"))
    }

    @Test
    fun `feedback validation rejects locally`() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)
        val results = mutableListOf<FeedbackResult>()
        client.sendFeedback(FeedbackKind.BUG, "  ") { results.add(it) }
        client.sendFeedback(FeedbackKind.BUG, "x", rating = 6) { results.add(it) }
        client.sendFeedback(FeedbackKind.BUG, "a".repeat(5001)) { results.add(it) }
        assertEquals(FeedbackResult.Rejected("message is required"), results[0])
        assertEquals(FeedbackResult.Rejected("rating must be an integer from 1 to 5"), results[1])
        assertTrue(results[2] is FeedbackResult.Rejected)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `offline feedback is queued then delivered`() {
        val store = MemoryStore()
        val net = TestSupport.NETWORK_ERROR
        val transport = FakeTransport(net, 503, net)
        val client = TestSupport.makeClient(transport, store)
        var result: FeedbackResult? = null
        client.sendFeedback(FeedbackKind.QUESTION, "How?") { result = it }
        assertEquals(FeedbackResult.Queued, result)
        assertEquals(listOf("/api/sdk/v1/feedback"), RequestQueue(store).load().map { it.path })
        client.flush()
        assertTrue(RequestQueue(store).load().isEmpty())
        assertEquals(4, transport.at("/feedback").size)
    }

    @Test
    fun `server rejection is not queued`() {
        val store = MemoryStore()
        val client = TestSupport.makeClient(FakeTransport(400), store)
        var result: FeedbackResult? = null
        client.sendFeedback(FeedbackKind.PRAISE, "Love it", 5) { result = it }
        assertEquals(FeedbackResult.Rejected("HTTP 400"), result)
        assertTrue(RequestQueue(store).load().isEmpty())
    }

    @Test
    fun `reset keeps queued feedback and buffered events under the original user`() {
        val store = MemoryStore()
        val net = TestSupport.NETWORK_ERROR
        val transport = FakeTransport(200, net, net, net)
        val client = TestSupport.makeClient(transport, store)
        client.identify("user_old")
        var result: FeedbackResult? = null
        client.sendFeedback(FeedbackKind.BUG, "broken") { result = it }
        assertEquals(FeedbackResult.Queued, result)
        client.track("tap")

        client.reset()
        assertEquals(listOf("/api/sdk/v1/feedback"), RequestQueue(store).load().map { it.path })

        client.flush()
        assertEquals("user_old", transport.at("/feedback").last().json.getString("appUserId"))
        val events = transport.at("/events").single().json.getJSONArray("events")
        assertEquals("user_old", events.getJSONObject(0).getString("appUserId"))
        assertTrue(RequestQueue(store).load().isEmpty())
        assertTrue(client.appUserId().startsWith("\$anon_"))
    }
}
