# RevenueHog Android SDK

`com.revenuehog:revenuehog-android` — user-level attribution for
[RevenueHog](https://revenuehog.dev). Kotlin, minSdk 24, zero dependencies
(HttpURLConnection + org.json, both ship with the platform), ~500 lines.

> **You don't need this SDK to use RevenueHog.** Revenue tracking works
> server-side from your App Store Connect `.p8` key. And to be direct:
> **RevenueHog ingests Apple App Store revenue today** — this Android SDK
> exists for *identity parity* across your platforms and for future Google
> Play support. `identify` / `setAttributes` enrich customer profiles now;
> `attributePurchase` stores the purchase→user mapping server-side so your
> history lights up the moment Play ingestion ships.

## Install

Maven Central (placeholder — publishing lands with the first tagged release):

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
        RevenueHog.configure(this, "pk_live_…") // ← the one line
    }
}
```

When you know who the user is:

```kotlin
RevenueHog.identify("user_42")
```

Anything reported before login (under a persisted anonymous id) is
re-attributed to `user_42`.

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
| `RevenueHog.configure(context, apiKey, options = Options())` | Sets up the SDK. Call once in `Application.onCreate()`. Never throws. |
| `RevenueHog.identify(userId)` | Links the anonymous id (and prior reports) to your user id. |
| `RevenueHog.setAttributes(map)` | Attaches flat string key/values to the user's profile. |
| `RevenueHog.attributePurchase(purchaseToken, productId?)` | Stores purchase→user mapping (for future Play ingestion). |
| `RevenueHog.billingListener(delegate?)` | Reflection-based `PurchasesUpdatedListener` wrapper (see above). |
| `RevenueHog.reset()` | Forgets the user on logout; issues a fresh anonymous id. |
| `RevenueHog.flush()` | Retries the offline queue. |

### Options

```kotlin
RevenueHog.configure(this, "pk_live_…", Options(
    baseUrl = "https://hog.internal.example", // self-hosted / dev
    logLevel = LogLevel.DEBUG,                // default WARN
))
```

## When do I need this?

| You want | SDK needed? |
|---|---|
| Apple revenue feed, MRR, churn, push alerts | **No** — `.p8` server-side ingestion covers it |
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
- Requires the `INTERNET` permission (which your app almost certainly
  already declares).

## Troubleshooting

- **Nothing in logcat** — filter by tag `RevenueHog`; pass
  `Options(logLevel = LogLevel.DEBUG)` to watch requests.
- **401 logged** — bad key; it must start with `pk_live_`.
- **Where's my Android revenue?** — Apple ingestion is live today; Play
  ingestion is on the roadmap. Your `attributePurchase` calls are already
  being stored server-side.
- **Self-hosting** — point `Options.baseUrl` at your deployment; paths are
  `/api/sdk/v1/identify` and `/api/sdk/v1/attribute`.

## Tests

```sh
cd kotlin && ./gradlew test
```

Plain JVM unit tests (no Robolectric, no emulator): payload building, queue
persistence, retry/backoff, identity aliasing — all against a fake transport
and in-memory store.
