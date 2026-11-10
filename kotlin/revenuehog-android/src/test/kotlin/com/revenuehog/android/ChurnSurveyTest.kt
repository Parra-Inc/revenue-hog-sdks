package com.revenuehog.android

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class ChurnSurveyTest {
    private val surveyJson = """
        {"survey":{"version":3,"title":"Why are you leaving?","options":[
        {"key":"too_expensive","title":"It's too expensive"},{"key":"not_using","title":"I don't use it enough"},
        {"key":"missing_feature","title":"Missing a feature"},{"key":"found_another_app","title":"Found another app"}],
        "other":{"enabled":true,"placeholder":"Tell us more","key":"other"},"randomize":true,
        "trigger":{"onAutoRenewOff":true,"maxPerUserDays":90},"sampleRate":1},"show":true,"reason":null}
    """.trimIndent()
    private val day = 86_400_000L

    private fun opts(vararg keys: String) = keys.map { ChurnSurveyOption(it, it) }

    @Test
    fun shufflesWithOtherLast() {
        val random = Random(7)
        val seen = mutableSetOf<List<String>>()
        repeat(30) {
            val ordered = ChurnSurveyRules.order(opts("a1", "b1", "other", "c1", "d1"), true, random)
            assertEquals(setOf("a1", "b1", "c1", "d1"), ordered.map { it.key }.toSet())
            assertEquals("other", ChurnSurveyRules.shownOrder(ordered, true).last())
            seen.add(ordered.map { it.key })
        }
        assertTrue(seen.size > 1)
        assertEquals(listOf("a1", "b1"), ChurnSurveyRules.order(opts("a1", "b1"), false).map { it.key })
    }

    @Test
    fun frequencyCap() {
        val now = 1_800_000_000_000L
        assertFalse(ChurnSurveyRules.isCapped(null, now, 90))
        assertTrue(ChurnSurveyRules.isCapped(now - 89 * day, now, 90))
        assertFalse(ChurnSurveyRules.isCapped(now - 91 * day, now, 90))
        assertFalse(ChurnSurveyRules.isCapped(now, now, 0))
    }

    @Test
    fun samplingMatchesServerHash() {
        assertEquals(0xe40c292cL, ChurnSurveyRules.fnv1a("a"))
        assertTrue(ChurnSurveyRules.inSample(1.0, "x"))
        assertFalse(ChurnSurveyRules.inSample(0.0, "x"))
        val hits = (0 until 2000).count { ChurnSurveyRules.inSample(0.25, "user_$it") }
        assertTrue("got $hits", hits in 350..650)
    }

    @Test
    fun asksOncePerCancellation() {
        assertEquals(listOf("t1"), ChurnSurveyRules.newlyCancelled(listOf("t1" to false), emptySet()).first)
        assertEquals(emptyList<String>(), ChurnSurveyRules.newlyCancelled(listOf("t1" to false), setOf("t1")).first)
        assertEquals(emptySet<String>(), ChurnSurveyRules.newlyCancelled(listOf("t1" to true), setOf("t1")).second)
    }

    @Test
    fun fetchUsesGetAndCapsLocally() {
        val transport = FakeTransport()
        transport.getBodies.addAll(listOf(surveyJson, surveyJson))
        val client = TestSupport.makeClient(transport)
        var survey: ChurnSurvey? = null
        client.churnSurvey(false) { survey = it }
        assertNotNull(survey)
        assertEquals(3, survey!!.version)
        assertEquals("other", survey!!.shownOrder.last())
        assertTrue(transport.requests[0].url.startsWith("https://example.test/api/sdk/v1/churn-survey?bundleId=com.example.app"))
        client.churnSurveyShown()
        var again: ChurnSurvey? = survey
        client.churnSurvey(false) { again = it }
        assertNull(again)
    }

    @Test
    fun respectsShowFalseAndAutoSwitch() {
        val noAuto = surveyJson.replace("\"onAutoRenewOff\":true", "\"onAutoRenewOff\":false")
        val transport = FakeTransport()
        transport.getBodies.addAll(listOf("""{"survey":null,"show":false,"reason":"disabled"}""", noAuto, noAuto))
        val client = TestSupport.makeClient(transport)
        val results = mutableListOf<ChurnSurvey?>()
        client.churnSurvey(false) { results.add(it) }
        client.churnSurvey(true) { results.add(it) }
        client.churnSurvey(false) { results.add(it) }
        assertNull(results[0])
        assertNull(results[1])
        assertNotNull(results[2])
    }

    @Test
    fun submitPostsAnswerWithShownOrder() {
        val transport = FakeTransport()
        transport.getBodies.add(surveyJson)
        val client = TestSupport.makeClient(transport)
        var survey: ChurnSurvey? = null
        client.churnSurvey(false) { survey = it }
        client.submitChurnSurvey(survey!!, ChurnSurveyResult.Other("  Only needed it for tax season "), "pro.monthly")
        client.submitChurnSurvey(survey!!, ChurnSurveyResult.Skipped, null)
        val posts = transport.requests.filter { it.url.endsWith("/churn-survey/response") }
        assertEquals("Only needed it for tax season", posts[0].json.getString("otherText"))
        assertEquals(survey!!.shownOrder, (0 until posts[0].json.getJSONArray("shownOrder").length()).map { posts[0].json.getJSONArray("shownOrder").getString(it) })
        assertEquals(3, posts[0].json.getInt("surveyVersion"))
        assertEquals("pro.monthly", posts[0].json.getString("productId"))
        assertTrue(posts[1].json.getBoolean("skipped"))
    }

    @Test
    fun dailyOpenOncePerUtcDay() {
        val transport = FakeTransport()
        var now = 1_800_000_000_000L
        val client = TestSupport.makeClient(transport, now = { now })
        client.sendDailyOpen()
        client.sendDailyOpen()
        assertEquals(1, transport.requests.count { it.url.endsWith("/api/sdk/v1/open") })
        assertTrue(transport.requests[0].json.getString("appUserId").startsWith("\$anon_"))
        now += day
        client.sendDailyOpen()
        assertEquals(2, transport.requests.count { it.url.endsWith("/api/sdk/v1/open") })
    }

    @Test
    fun firstIdentifyCarriesAnonymousId() {
        val transport = FakeTransport()
        val client = TestSupport.makeClient(transport)
        val anon = client.appUserId()
        client.identify("user_1")
        client.identify("user_2")
        val ids = transport.requests.filter { it.url.endsWith("/identify") }
        assertEquals(anon, ids[0].json.getString("anonymousAppUserId"))
        assertFalse(ids[1].json.has("anonymousAppUserId"))
    }

    @Test
    fun parseReturnsNullWhenNothingToShow() {
        assertNull(ChurnSurveyRules.parse(null))
        assertNull(ChurnSurveyRules.parse(JSONObject("""{"options":[],"other":{"enabled":false}}""")))
    }
}
