# Changelog

All three SDKs (Swift package tag, `com.revenuehog:revenuehog-android`,
`@revenuehog/react-native`) share one version number.

## 0.4.0 (unreleased)

### Added
- React Native: optional built-in churn survey UI. Mount `<ChurnSurveyHost />`
  once and `presentChurnSurvey()` (and the Android auto-renew-off trigger)
  shows a modal sheet matching the native SDKs: randomized options, "Other"
  last with a text field, Skip and Send. `<ChurnSurveySheet />` is the same
  sheet as a controlled component. `react` and `react-native` are optional
  peer dependencies, loaded only when the sheet renders, so headless use is
  unaffected. A configured `churnSurveyPresenter` still takes precedence.
- React Native: `churnSurveyLabels(locale?, overrides?)` returns the bundled
  localized button labels for custom UIs.
- Localized "Other", "Skip" and "Send" labels in 17 locales (en, ar, de, es,
  fr, it, ja, ko, nl, pl, pt-BR, pt-PT, ru, sv, tr, zh-Hans, zh-Hant), with
  English fallback. Swift: `Localizable.strings` in the package bundle
  (`Bundle.module`; the package now declares `defaultLocalization: "en"`).
  Kotlin: `res/values-xx` strings named `revenuehog_churn_survey_*`, which
  host apps can override.
- Churn survey "Allow additional info": when the dashboard turns on
  `allowAdditionalInfo`, the built-in survey on all three SDKs shows an
  optional "Tell us more (optional)" field under any answer (localized into
  the same 17 locales) and sends it as `additionalInfo`. When it is off the
  field is hidden and nothing is sent. Swift `ChurnSurveyResult.option` and
  `.other` and Kotlin `ChurnSurveyResult.Option` and `.Other` gain an
  optional `additionalInfo`; React Native results gain `additionalInfo?`, and
  `ChurnSurveyLabels` gains `additionalInfo`.

### Changed
- React Native: the Android auto-renew-off check runs whenever
  `churnSurveyAutoTrigger` is not `false`, not only when a presenter is
  configured, so the built-in sheet can be used. With no presenter and no
  host mounted it stays silent and retries on the next launch.

### Fixed
- React Native docs referred to `autoRenewTurnedOff()`; the method is
  `autoRenewChanged()`.

## 0.3.0 (unreleased)

### Added
- Churn survey on all three SDKs: `presentChurnSurvey`, an auto-renew-off
  trigger, sampling and a per-user frequency cap, with answers and skips
  recorded.
- Daily customer open ping.
