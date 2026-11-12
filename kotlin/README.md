# RevenueHog Android SDK

`com.revenuehog:revenuehog-android`: user-level attribution for
[RevenueHog](https://revenuehog.dev). Kotlin, minSdk 24, zero dependencies
(HttpURLConnection + org.json, both ship with the platform), ~500 lines.

> **You don't need this SDK to use RevenueHog.** Revenue tracking works
> server-side from your App Store Connect `.p8` key. And to be direct:
> **RevenueHog ingests Apple App Store revenue today**; this Android SDK
> exists for *identity parity* across your platforms and for future Google
> Play support. `identify` / `setAttributes` enrich customer profiles now;
> `attributePurchase` stores the purchase→user mapping server-side so your
> history lights up the moment Play ingestion ships.

## Install

Maven Central (placeholder, publishing lands with the first tagged release):

```kotlin
// build.gradle.kts
dependencies {
    implementation("com.revenuehog:revenuehog-android:0.1.0")
}
```

Until then, include the module from source or a Maven local publish
(`./gradlew publishToMavenLocal`).

## 60-second quickstart

One required line, in `Application.onCreate()`:

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        RevenueHog.configure(this) // ← the one line, no key needed
    }
}
```

When you know who the user is:

```kotlin
RevenueHog.identify("user_42")
```

Anything reported before login (under a persisted anonymous id) is
re-attributed to `user_42`.

### How auth works

There is no API key. The server maps requests to your org by package name,
and identity data from this SDK is labeled **unverified** in the RevenueHog
dashboard until attestation support lands (Play Integrity is planned).

### Play Billing (optional)

If you use Play Billing, either wrap your listener:

```kotlin
val listener = RevenueHog.billingListener(myListener) as PurchasesUpdatedListener
val billingClient = BillingClient.newBuilder(context)
    .setListener(listener)
    .enablePendingPurchases()
    .build()
```

…or call `attributePurchase` yourself from your `PurchasesUpdatedListener`:

```kotlin
override fun onPurchasesUpdated(result: BillingResult, purchases: List<Purchase>?) {
    purchases?.forEach { purchase ->
        RevenueHog.attributePurchase(
            purchaseToken = purchase.purchaseToken,
            productId = purchase.products.firstOrNull(),
        )
    }
}
```

`billingListener` is built with reflection so the SDK itself never depends on
Play Billing. If the billing library isn't on the classpath it hands back
your delegate untouched.

## API reference

| Call | What it does |
|---|---|
| `RevenueHog.configure(context, options = Options())` | Sets up the SDK. Call once in `Application.onCreate()`. Never throws. |
| `RevenueHog.identify(userId)` | Links the anonymous id (and prior reports) to your user id. |
| `RevenueHog.setAttributes(map)` | Attaches flat string key/values to the user's profile. |
| `RevenueHog.attributePurchase(purchaseToken, productId?)` | Stores purchase→user mapping (for future Play ingestion). |
| `RevenueHog.billingListener(delegate?)` | Reflection-based `PurchasesUpdatedListener` wrapper (see above). |
| `RevenueHog.reset()` | Forgets the user on logout; issues a fresh anonymous id. Queued requests and unsent events keep the user they were recorded under and still deliver. |
| `RevenueHog.flush()` | Sends buffered events and retries the offline queue. |
| `RevenueHog.installId` | This install's id, an uppercase UUID string, unchanged by `reset()`. `null` before `configure()`. |
| `RevenueHog.track(name, properties?)` | Records a funnel milestone (snake_case name, flat map of strings, numbers, booleans). Persisted, sent in batches of up to 50. |
| `RevenueHog.sendFeedback(kind, message, rating?, data?, metadata?, onResult?)` | Sends in-app feedback (`FeedbackKind.BUG`, `IDEA`, `QUESTION`, `PRAISE`) with device context. `onResult` (SDK thread) gets `FeedbackResult.Sent(id)`, `Queued` or `Rejected(reason)`. |
| `RevenueHog.presentChurnSurvey(activity, productId?, onResult?)` | Shows the churn survey dialog now and records the answer. |
| `RevenueHog.checkPurchasesForChurn(activity, purchases)` | Pass Play Billing purchases; shows the survey once when a subscription's auto-renew turns off. |
| `RevenueHog.autoRenewChanged(activity, purchaseToken, willAutoRenew, productId?)` | Same, for apps that track renewal state themselves. |

### Options

```kotlin
RevenueHog.configure(this, Options(
    baseUrl = "https://hog.internal.example", // self-hosted / dev
    logLevel = LogLevel.DEBUG,                // default WARN
))
```

### Install id

`RevenueHog.installId` is the same per-install UUID the iOS SDK hands to
StoreKit as `appAccountToken`. Play Billing has no `appAccountToken`; if you
want a per-install key on Play purchases, pass it to
`BillingFlowParams.Builder.setObfuscatedAccountId(...)` (64 characters max,
which a UUID fits).

## Events and feedback

```kotlin
RevenueHog.track("onboarding_step", mapOf("step" to "welcome", "index" to 0))
RevenueHog.sendFeedback(FeedbackKind.BUG, "Export crashes", rating = 2) { result -> }
```

Same rules as the other SDKs: snake_case event names (max 48 characters,
no `rh_` prefix), batches of up to 50 sent when 20 are waiting, about 10
seconds after the first, on `flush()` and on the next launch. Feedback adds
`osVersion`, `deviceModel`, `locale` and `appVersion` to `metadata`; offline
feedback is queued and delivered later.

**Apple Ads (AdServices) does not apply on Android.** It is an Apple-only
attribution framework, so there is no `sendAdServicesToken` here. Use Play
Install Referrer or your ad network's SDK for Android install attribution.

## Churn survey

Ask why someone is leaving, with the options you configure in the
RevenueHog dashboard (Retention, Churn survey). Single choice plus an
optional "Other" text field. Options are shuffled per user when the
dashboard says so, "Other" always stays last, and the order shown is sent
with the answer so position bias can be measured. A survey appears at most
once per user per 90 days (configurable), and the dashboard's sample rate
applies. Skips are recorded too, so response rates are honest. Do not ask
for personal data in the "Other" field.

The SDK ships a platform `AlertDialog`, so there is nothing to build:

```kotlin
// Before opening subscription management:
RevenueHog.presentChurnSurvey(activity, productId = "pro_monthly") { result -> openPlaySubscriptions() }

// After queryPurchasesAsync, for the automatic trigger:
RevenueHog.checkPurchasesForChurn(activity, purchases)
```

The "Other", "Skip" and "Send" labels ship as `res/values-xx` strings
(17 locales, English fallback); override any of them in your app with the
same resource names (`revenuehog_churn_survey_other`, `_skip`, `_send`).
The survey title, options and placeholder come localized from the dashboard.

## Customer opens

`configure()` sends one `POST /api/sdk/v1/open` per device per UTC day with
the current app user id, so every person who opens the app counts as a
customer. The first `identify()` sends the anonymous id so the server merges
the two.

## When do I need this?

| You want | SDK needed? |
|---|---|
| Apple revenue feed, MRR, churn, push alerts | **No**, `.p8` server-side ingestion covers it |
| Same user identity across your iOS + Android apps | Yes |
| Device model / OS / locale on customer profiles | Yes |
| Custom attributes (`plan`, `cohort`, …) | Yes |
| Play purchase→user mapping ready for Play ingestion | Yes |

## Behavior notes

- **Never crashes your app.** Every public call is fire-and-forget onto a
  single background daemon thread; every failure is swallowed into
  `Log.d("RevenueHog", …)`. Calling anything before `configure` is a no-op.
- **Offline-safe.** Failed requests (network, `429`, `5xx`) retry with
  exponential backoff (max 3 attempts), then persist to a SharedPreferences
  queue (cap 100) that flushes on the next call / launch.
- **Idempotent.** The API dedupes server-side; the SDK also skips purchases
  already reported for the current user.
- **Private.** Sends only: your user id (or an anonymous UUID), package
  name, OS version, device model, locale, and attributes you pass. No ad id.
- **Unverified until attested.** Requests carry no credentials, so identity
  data from this SDK is labeled unverified in the dashboard until attestation
  support (Play Integrity) lands.
- Requires the `INTERNET` permission (which your app almost certainly
  already declares).

## Troubleshooting

- **Nothing in logcat**: filter by tag `RevenueHog`; pass
  `Options(logLevel = LogLevel.DEBUG)` to watch requests.
- **Customer rows labeled unverified**: expected for this SDK today; the
  label clears once attestation support ships.
- **Where's my Android revenue?**: Apple ingestion is live today; Play
  ingestion is on the roadmap. Your `attributePurchase` calls are already
  being stored server-side.
- **Self-hosting**: point `Options.baseUrl` at your deployment; paths are
  `/api/sdk/v1/identify` and `/api/sdk/v1/attribute`.

## Tests

```sh
cd kotlin && ./gradlew test
```

Plain JVM unit tests (no Robolectric, no emulator): payload building, queue
persistence, retry/backoff, identity aliasing, all against a fake transport
and in-memory store.
