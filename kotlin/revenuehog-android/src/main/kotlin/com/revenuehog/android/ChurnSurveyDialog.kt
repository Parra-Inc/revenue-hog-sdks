package com.revenuehog.android

import android.app.Activity
import android.app.AlertDialog
import android.widget.EditText
import android.widget.LinearLayout

/**
 * The built-in survey: a platform AlertDialog with a single-choice list, an
 * "Other" text field when enabled, an optional additional info field when
 * the survey allows it, and Skip / Send. No AppCompat or Material
 * dependency, so it inherits the host theme's dialog style. The button and
 * "Other" labels come from res/values-xx (17 locales, English fallback).
 */
internal object ChurnSurveyDialog {
    fun show(activity: Activity, survey: ChurnSurvey, onFinish: (ChurnSurveyResult) -> Unit) {
        val labels = survey.options.map { it.title } +
            if (survey.otherEnabled) listOf(activity.getString(R.string.revenuehog_churn_survey_other)) else emptyList()
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
        val additional = EditText(activity).apply {
            hint = activity.getString(R.string.revenuehog_churn_survey_additional_info)
            contentDescription = hint
            isEnabled = false
        }
        val container = LinearLayout(activity).apply {
            orientation = LinearLayout.VERTICAL
            val pad = (20 * activity.resources.displayMetrics.density).toInt()
            setPadding(pad, 0, pad, 0)
            if (survey.otherEnabled) addView(other)
            if (survey.allowAdditionalInfo) addView(additional)
        }
        fun info(): String? =
            if (survey.allowAdditionalInfo) additional.text?.toString()?.trim()?.ifEmpty { null } else null

        val dialog = AlertDialog.Builder(activity)
            .setTitle(survey.title)
            .setSingleChoiceItems(labels.toTypedArray(), -1) { _, which ->
                selected = which
                other.isEnabled = keys.getOrNull(which) == ChurnSurveyRules.OTHER_KEY
                additional.isEnabled = true
            }
            .setView(container)
            .setNegativeButton(R.string.revenuehog_churn_survey_skip) { _, _ -> finish(ChurnSurveyResult.Skipped) }
            .setPositiveButton(R.string.revenuehog_churn_survey_send) { _, _ ->
                val key = keys.getOrNull(selected)
                finish(
                    when {
                        key == null -> ChurnSurveyResult.Skipped
                        key == ChurnSurveyRules.OTHER_KEY -> {
                            val text = other.text?.toString()?.trim().orEmpty()
                            if (text.isEmpty()) ChurnSurveyResult.Skipped else ChurnSurveyResult.Other(text, info())
                        }
                        else -> ChurnSurveyResult.Option(key, info())
                    },
                )
            }
            .setOnCancelListener { finish(ChurnSurveyResult.Skipped) }
            .create()
        dialog.show()
    }
}
