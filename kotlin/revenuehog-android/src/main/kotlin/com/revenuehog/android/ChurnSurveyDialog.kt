package com.revenuehog.android

import android.app.Activity
import android.app.AlertDialog
import android.widget.EditText
import android.widget.LinearLayout

/**
 * The built-in survey: a platform AlertDialog with a single-choice list, an
 * "Other" text field when enabled, and Skip / Send. No AppCompat or Material
 * dependency, so it inherits the host theme's dialog style.
 */
internal object ChurnSurveyDialog {
    fun show(activity: Activity, survey: ChurnSurvey, onFinish: (ChurnSurveyResult) -> Unit) {
        val labels = survey.options.map { it.title } +
            if (survey.otherEnabled) listOf("Other") else emptyList()
        val keys = survey.shownOrder
        var selected = -1
        var finished = false
        fun finish(result: ChurnSurveyResult) {
            if (finished) return
            finished = true
            onFinish(result)
        }

        val other = EditText(activity).apply {
            hint = survey.otherPlaceholder
            isEnabled = false
        }
        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (20 * activity.resources.displayMetrics.density).toInt()
            setPadding(pad, 0, pad, 0)
            if (survey.otherEnabled) addView(other)
        }

        val dialog = AlertDialog.Builder(activity)
            .setTitle(survey.title)
            .setSingleChoiceItems(labels.toTypedArray(), -1) { _, which ->
                selected = which
                other.isEnabled = keys.getOrNull(which) == ChurnSurveyRules.OTHER_KEY
            }
            .setView(container)
            .setNegativeButton("Skip") { _, _ -> finish(ChurnSurveyResult.Skipped) }
            .setPositiveButton("Send") { _, _ ->
                val key = keys.getOrNull(selected)
                finish(
                    when {
                        key == null -> ChurnSurveyResult.Skipped
                        key == ChurnSurveyRules.OTHER_KEY -> {
                            val text = other.text?.toString()?.trim().orEmpty()
                            if (text.isEmpty()) ChurnSurveyResult.Skipped else ChurnSurveyResult.Other(text)
                        }
                        else -> ChurnSurveyResult.Option(key)
                    },
                )
            }
            .setOnCancelListener { finish(ChurnSurveyResult.Skipped) }
            .create()
        dialog.show()
    }
}
