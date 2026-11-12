# Changelog

All three SDKs (Swift package tag, `com.revenuehog:revenuehog-android`,
`@revenuehog/react-native`) share one version number.

## 0.5.3 (unreleased)

### Fixed
- React Native: automatic attribution now works with react-native-iap 14
  and 15. On iOS those versions carry the StoreKit 2 signed transaction in
  the unified `purchaseToken`, which the SDK now sends as `jws` (when it looks
  like a JWS) and no longer mistakes for the transaction id. The purchase's
  `platform`, platform-suffixed fields, then `Platform.OS` decide iOS versus
  Android; `jwsRepresentationIos` still wins on react-native-iap 13, and the
  unified `id` is a transaction id fallback. Android renewal state also reads
  the unified `isAutoRenewing` on purchases marked Android.
- React Native: `ChurnSurveyHost` and `ChurnSurveySheet` are typed to return
  a React element shape instead of `unknown`, so `<ChurnSurveyHost />`
  typechecks in an app without a cast (TS2786). React stays an optional peer.

### Added
- The install id is public, for StoreKit's `appAccountToken`:
  React Native `RevenueHog.getInstallId()`, Swift `await RevenueHog.installId`
  and `await RevenueHog.appAccountToken` (a `UUID`), Kotlin
  `RevenueHog.installId`. It is an uppercase UUID string on every platform.

## 0.5.2 (2026-11-12)

### Fixed
- Swift: automatic AdServices capture no longer re-sends the token for
  installs that reported it themselves before adopting the SDK. If any of the
  legacy `UserDefaults.standard` flags `revenuehog.adservices.reported`,
  `attribution.adservices.reported`, `adservices.attribution.reported` or
  `adservices.reported` is true, the SDK marks AdServices as sent and skips
  capture. Previously those installs created a duplicate attribution row
  under the SDK's new install id. The legacy keys are read only, never
  modified.

## 0.5.1 (2026-11-11)

### Fixed
- `reset()` no longer discards pending work on any SDK. It only rotates
  identity: queued feedback, AdServices and event requests, and buffered
  events, keep the `appUserId` they were recorded under and still deliver
  after logout. Previously `reset()` cleared the offline queue and the event
  buffer.
- AdServices (Swift automatic capture, React Native `sendAdServicesToken`):
  the once-per-install sent flag is now set only after the server answers
  (2xx, or a permanent rejection it will never accept), including when a
  queued request lands on a later flush. While a request is queued no
  duplicate is enqueued, and if the queue drops it the token is sent again
  on a later launch or call. Previously the flag was set as soon as the
  request was queued, so a dropped request was never retried.

## 0.5.0 (2026-11-11)

### Added
- Events on all three SDKs: `track(name, properties?)` records funnel
  milestones to `POST /api/sdk/v1/events`. Events are persisted, sent in
  batches of up to 50 (when 20 are waiting, about 10 seconds after the
  first, on `flush()` and on the next launch), and queued when offline.
  Names are validated on device (snake_case, max 48 characters, no `rh_`).
  Swift adds a `PropertyValue` type (string, int, double, bool literals).
- In-app feedback on all three SDKs: Swift `sendFeedback(kind:message:...)
  async -> FeedbackResult`, React Native `sendFeedback(input):
  Promise<FeedbackResult>`, Kotlin `sendFeedback(kind, message, ...,
  onResult)`. Kinds are bug, idea, question and praise; device context
  (OS version, model, locale, app version) is merged into `metadata`;
  offline feedback is queued and delivered later.
- Apple Ads attribution: the Swift SDK reads
  `AAAttribution.attributionToken()` once per install and sends it to
  `POST /api/sdk/v1/adservices` (`Options.enableAdServicesAttribution`,
  default `true`). React Native gains `sendAdServicesToken(token, options?)`
  for a token the app reads natively. Not applicable on Android.
- Swift: public `RevenueHog.flush() async`, and `attributePurchase` takes an
  optional `jws`, matching React Native.

### Changed
- `flush()` on all three SDKs also sends buffered events.
- Feedback and AdServices requests carry the app version (Swift
  `CFBundleShortVersionString`, Kotlin `versionName`, React Native via
  `expo-application` or `react-native-device-info`).

## 0.4.0

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
