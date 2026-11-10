package com.revenuehog.android

import org.json.JSONObject
import java.util.Calendar
import java.util.TimeZone
import kotlin.random.Random

/** One choice in the churn survey. [key] is stable; [title] is localized. */
data class ChurnSurveyOption(val key: String, val title: String)

/**
 * The churn survey as it should render: [options] already in display order
 * (shuffled when the dashboard says so), with "Other" always last.
 * [shownOrder] is sent back with the answer so position bias can be measured.
 * [allowAdditionalInfo] shows an optional free-text field that goes with any
 * answer; when false the field is hidden and additional info is never sent.
 */
data class ChurnSurvey(
    val version: Int,
    val title: String,
    val options: List<ChurnSurveyOption>,
    val otherEnabled: Boolean,
    val otherPlaceholder: String,
    val shownOrder: List<String>,
    val allowAdditionalInfo: Boolean = false,
)

/** What happened when the survey was presented. */
sealed class ChurnSurveyResult {
    data class Option(val key: String, val additionalInfo: String? = null) : ChurnSurveyResult()
    data class Other(val text: String, val additionalInfo: String? = null) : ChurnSurveyResult()
    object Skipped : ChurnSurveyResult()

    /** No survey configured, disabled, not sampled, capped, or not configured. */
    object NotShown : ChurnSurveyResult()
}

internal data class ParsedSurvey(
    val survey: ChurnSurvey,
    val autoRenewTrigger: Boolean,
    val maxPerUserDays: Int,
    val sampleRate: Double,
)

/** Pure survey rules, free of networking and UI so they are unit tested. */
internal object ChurnSurveyRules {
    const val OTHER_KEY = "other"
    const val DEFAULT_MAX_PER_USER_DAYS = 90
    private const val DAY_MS = 86_400_000L

    /** Render order: shuffled when [randomize]; "Other" never in the list. */
    fun order(options: List<ChurnSurveyOption>, randomize: Boolean, random: Random = Random.Default): List<ChurnSurveyOption> {
        val live = options.filter { it.key != OTHER_KEY }
        return if (randomize) live.shuffled(random) else live
    }

    fun shownOrder(options: List<ChurnSurveyOption>, otherEnabled: Boolean): List<String> =
        options.map { it.key } + if (otherEnabled) listOf(OTHER_KEY) else emptyList()

    /** True while the last appearance is inside the cap window. 0 days = no cap. */
    fun isCapped(lastShownAt: Long?, now: Long, maxPerUserDays: Int): Boolean {
        if (lastShownAt == null || maxPerUserDays <= 0) return false
        return now - lastShownAt < maxPerUserDays * DAY_MS
    }

    /** 32-bit FNV-1a over UTF-16 code units, identical to the server's. */
    fun fnv1a(s: String): Long {
        var h = 0x811c9dc5L
        for (c in s) {
            h = h xor c.code.toLong()
            h = (h * 0x01000193L) and 0xffffffffL
        }
        return h
    }

    /** Deterministic sampling; used only when the server sent no `show`. */
    fun inSample(sampleRate: Double, seed: String): Boolean {
        if (sampleRate >= 1) return true
        if (sampleRate <= 0) return false
        return fnv1a(seed).toDouble() / 4_294_967_296.0 < sampleRate
    }

    /**
     * Ids whose auto-renew newly turned off, plus the next handled set (ids
     * that renew again drop out so a later cancel asks again).
     */
    fun newlyCancelled(renewals: List<Pair<String, Boolean>>, handled: Set<String>): Pair<List<String>, Set<String>> {
        val next = handled.toMutableSet()
        val fresh = mutableListOf<String>()
        for ((id, willAutoRenew) in renewals) {
            if (willAutoRenew) next.remove(id) else if (id !in next) fresh.add(id)
        }
        return fresh to next
    }

    /** Lenient decode of the `survey` object; null when nothing to show. */
    fun parse(raw: JSONObject?, random: Random = Random.Default): ParsedSurvey? {
        if (raw == null) return null
        val options = mutableListOf<ChurnSurveyOption>()
        raw.optJSONArray("options")?.let { arr ->
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                val key = o.optString("key")
                val title = o.optString("title")
                if (key.isNotEmpty() && title.isNotEmpty()) options.add(ChurnSurveyOption(key, title))
            }
        }
        val other = raw.optJSONObject("other")
        val otherEnabled = other?.optBoolean("enabled", false) ?: false
        if (options.isEmpty() && !otherEnabled) return null
        val trigger = raw.optJSONObject("trigger")
        val ordered = order(options, raw.optBoolean("randomize", false), random)
        return ParsedSurvey(
            survey = ChurnSurvey(
                version = raw.optInt("version", 1).coerceAtLeast(1),
                title = raw.optString("title").ifEmpty { "Why are you leaving?" },
                options = ordered,
                otherEnabled = otherEnabled,
                otherPlaceholder = other?.optString("placeholder").orEmpty().ifEmpty { "Tell us more" },
                shownOrder = shownOrder(ordered, otherEnabled),
                allowAdditionalInfo = raw.optBoolean("allowAdditionalInfo", false),
            ),
            autoRenewTrigger = trigger?.optBoolean("onAutoRenewOff", true) ?: true,
            maxPerUserDays = trigger?.optInt("maxPerUserDays", DEFAULT_MAX_PER_USER_DAYS) ?: DEFAULT_MAX_PER_USER_DAYS,
            sampleRate = raw.optDouble("sampleRate", 1.0),
        )
    }

    /** UTC day key, "yyyy-mm-dd". */
    fun utcDay(ms: Long): String {
        val c = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        c.timeInMillis = ms
        return String.format(
            java.util.Locale.US, "%04d-%02d-%02d",
            c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH),
        )
    }
}
