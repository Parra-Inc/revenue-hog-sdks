# RevenueHog Swift SDK

User-level purchase attribution for [RevenueHog](https://revenuehog.dev), as a
Swift Package. iOS 15+, StoreKit 2, zero dependencies, ~500 lines.

> **You don't need this SDK to use RevenueHog.** Revenue tracking, the live
> feed, metrics, and push alerts all work server-side from your App Store
> Connect `.p8` key — no SDK, no code changes. Install this SDK only when you
> want *user-level attribution*: knowing which of **your** app users a
> purchase belongs to, plus device/locale context and custom attributes on
> customer profiles.

## Install

Xcode → File → Add Package Dependencies…

```
https://github.com/Parra-Inc/revenue-hog-sdks
```

Select the `RevenueHog` product. Or in `Package.swift`:

```swift
.package(url: "https://github.com/Parra-Inc/revenue-hog-sdks", from: "0.1.0")
```

## 60-second quickstart

One required line, at launch:

```swift
import RevenueHog

@main
struct MyApp: App {
    init() {
        RevenueHog.configure(apiKey: "pk_live_…") // ← the one line
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

Done. The SDK listens to StoreKit 2 `Transaction.updates` (plus current
entitlements once at launch) and attributes every verified transaction
automatically. Before anyone logs in, purchases attribute to a persisted
anonymous id.

When you know who the user is:

```swift
RevenueHog.identify(userId: "user_42")
```

Everything reported anonymously is re-attributed to `user_42`.

Your publishable key lives in the RevenueHog dashboard → settings → API
(`pk_live_…`). It's safe to ship in the app binary.

## API reference

| Call | What it does |
|---|---|
| `RevenueHog.configure(apiKey:options:)` | Sets up the SDK. Call once at launch. Starts the StoreKit 2 listener unless `options.enableAutoAttribution` is `false`. |
| `RevenueHog.identify(userId:)` | Links the anonymous id (and everything reported under it) to your user id. |
| `RevenueHog.setAttributes(_:)` | Attaches a flat `[String: String]` map to the user's profile (plan, cohort, …). |
| `RevenueHog.attributePurchase(originalTransactionId:productId:)` | Manual attribution. Only needed when auto-attribution is off. |
| `RevenueHog.reset()` | Forgets the user on logout; issues a fresh anonymous id. |

### Options

```swift
RevenueHog.configure(apiKey: "pk_live_…", options: Options(
    baseURL: URL(string: "https://hog.internal.example")!, // self-hosted / dev
    enableAutoAttribution: true,                            // default
    logLevel: .debug                                        // default .warn
))
```

## When do I need this?

| You want | SDK needed? |
|---|---|
| Revenue feed, MRR, churn, push alerts | **No** — `.p8` server-side ingestion covers it |
| Know *which app user* made a purchase | Yes |
| Device model / OS / locale on customer profiles | Yes |
| Custom attributes (`plan`, `cohort`, …) | Yes |

## Behavior notes

- **Never crashes your app.** Every failure is swallowed into the debug log.
  Calling any method before `configure` is a logged no-op.
- **Offline-safe.** Undeliverable requests (network down, `429` rate limits,
  `5xx`) retry with exponential backoff (max 3 attempts), then persist to a
  small on-disk queue (cap 100) that flushes on the next launch/call.
- **Idempotent.** Both endpoints dedupe server-side; the SDK also skips
  transactions it already reported for the current user.
- **Private.** Sends only: your user id (or an anonymous UUID), bundle id,
  OS version, device model, locale, and attributes you pass. No IDFA, no
  fingerprinting, no receipt payloads.

## Troubleshooting

- **Nothing shows up** — check the key starts with `pk_live_` (a `401` is
  logged at `.error`). Set `logLevel: .debug` to watch requests.
- **Purchases appear but aren't linked to users** — call
  `identify(userId:)` after login; earlier purchases re-attribute
  automatically.
- **Sandbox purchases** — attribution works in sandbox too; the dashboard
  hides sandbox data unless you enable it in settings.
- **Self-hosting** — point `Options.baseURL` at your deployment; paths are
  `/api/sdk/v1/identify` and `/api/sdk/v1/attribute`.

## Tests

```sh
cd swift && swift test
```

Queue persistence, payload encoding, retry/backoff, and identity aliasing are
covered against a mocked transport — no network needed.
