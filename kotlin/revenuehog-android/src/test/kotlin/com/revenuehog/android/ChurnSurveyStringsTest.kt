package com.revenuehog.android

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every bundled locale carries every churn survey label. */
class ChurnSurveyStringsTest {
    private val keys = setOf(
        "revenuehog_churn_survey_other",
        "revenuehog_churn_survey_skip",
        "revenuehog_churn_survey_send",
        "revenuehog_churn_survey_additional_info",
    )

    private fun strings(dir: File): Map<String, String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(File(dir, "strings.xml"))
        val nodes = doc.getElementsByTagName("string")
        return (0 until nodes.length).associate { i ->
            val n = nodes.item(i)
            n.attributes.getNamedItem("name").nodeValue to n.textContent
        }
    }

    @Test
    fun everyLocaleHasEveryLabel() {
        val res = File("src/main/res")
        val dirs = res.listFiles { f -> f.isDirectory && f.name.startsWith("values") }.orEmpty()
        assertTrue("expected the default plus 16 locales", dirs.size >= 17)
        for (dir in dirs) {
            val s = strings(dir)
            assertEquals(dir.name, keys, s.keys.filter { it in keys }.toSet())
            keys.forEach { assertTrue("${dir.name} $it", s[it].orEmpty().isNotBlank()) }
        }
    }

    @Test
    fun defaultIsEnglish() {
        val s = strings(File("src/main/res/values"))
        assertEquals("Other", s["revenuehog_churn_survey_other"])
        assertEquals("Skip", s["revenuehog_churn_survey_skip"])
        assertEquals("Send", s["revenuehog_churn_survey_send"])
        assertEquals("Tell us more (optional)", s["revenuehog_churn_survey_additional_info"])
    }
}
