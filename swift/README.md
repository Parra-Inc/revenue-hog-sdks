# RevenueHog Swift SDK

User-level purchase attribution for [RevenueHog](https://revenuehog.dev), as a
Swift Package. iOS 15+, StoreKit 2, zero dependencies, ~800 lines.

> **You don't need this SDK to use RevenueHog.** Revenue tracking, the live
> feed, metrics, and push alerts all work server-side from your App Store
> Connect `.p8` key, with no SDK and no code changes. Install this SDK only
> when you want *user-level attribution*: knowing which of **your** app users
> a purchase belongs to, plus device/locale context and custom attributes on
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

Then add the **App Attest capability** to your app target
(Signing & Capabilities → + Capability → App Attest). That's the only
project setting the SDK needs; see "How auth works" below.

## 60-second quickstart

One required line, at launch. No API key:

```swift
import RevenueHog

@main
struct MyApp: App {
    init() {
        RevenueHog.configure() // ← the one line
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

## How auth works

There is no API key and nothing to copy from a dashboard. On first launch
the SDK enrolls the device with Apple's
[App Attest](https://developer.apple.com/documentation/devicecheck) service:
Apple signs a statement that this is the genuine app with your bundle id
built by your team, the RevenueHog server verifies it and maps the bundle id
to your org (which it already knows from your App Store Connect key), and
the SDK receives an opaque device token. Every request after that carries
the token. It lives in the Keychain, is scoped to one (org, app, device),
is revocable from the dashboard, and is worthless for reading data.

When App Attest is unavailable (simulator, unsupported hardware, enrollment
not finished yet) the SDK still sends data, marked unattested. The server
accepts it but labels it **unverified** in the dashboard and quarantines it
from trusted writes. Attribution calls also carry the Apple-signed StoreKit
transaction (JWS), which the server verifies independently, so the purchase
link itself is trusted even from an unattested session.

**Requirement:** the app target must have the App Attest capability
(the `com.apple.developer.devicecheck.appattest-environment` entitlement).
The SDK checks its own binary at `configure()` on physical devices: DEBUG
builds hit an assertion with instructions if the entitlement is missing;
release builds log once and run unattested. Dev-signed builds attest against
Apple's sandbox automatically, so `production` is always the right value.

## API reference

| Call | What it does |
|---|---|
| `RevenueHog.configure(options:)` | Sets up the SDK and enrolls the device. Call once at launch. Starts the StoreKit 2 listener unless `options.enableAutoAttribution` is `false`. |
| `RevenueHog.identify(userId:)` | Links the anonymous id (and everything reported under it) to your user id. |
| `RevenueHog.setAttributes(_:)` | Attaches a flat `[String: String]` map to the user's profile (plan, cohort, …). |
| `RevenueHog.attributePurchase(originalTransactionId:productId:)` | Manual attribution. Only needed when auto-attribution is off. |
| `RevenueHog.reset()` | Forgets the user on logout; issues a fresh anonymous id. Device enrollment survives. |

### Options

```swift
RevenueHog.configure(options: Options(
    baseURL: URL(string: "https://hog.internal.example")!, // self-hosted / dev
    enableAutoAttribution: true,                            // default
    logLevel: .debug                                        // default .warn
))
```

## When do I need this?

| You want | SDK needed? |
|---|---|
| Revenue feed, MRR, churn, push alerts | **No**, `.p8` server-side ingestion covers it |
| Know *which app user* made a purchase | Yes |
| Device model / OS / locale on customer profiles | Yes |
| Custom attributes (`plan`, `cohort`, …) | Yes |

## Behavior notes

- **Never crashes your app.** Every failure is swallowed into the debug log.
  Calling any method before `configure` is a logged no-op.
- **Offline-safe.** Undeliverable requests (network down, `429` rate limits,
  `5xx`) retry with exponential backoff (max 3 attempts), then persist to a
  small on-disk queue (cap 100) that flushes on the next launch/call.
- **Startup-safe.** Calls made while enrollment is still in flight wait up
  to 10 seconds for the device token, then go out unattested so a slow first
  launch still delivers data.
- **Idempotent.** Both endpoints dedupe server-side; the SDK also skips
  transactions it already reported for the current user.
- **Private.** Sends only: your user id (or an anonymous UUID), bundle id,
  OS version, device model, locale, attributes you pass, and the Apple-signed
  transaction JWS for purchases. No IDFA, no fingerprinting.

## Troubleshooting

- **Nothing shows up**: set `logLevel: .debug` to watch requests, and make
  sure your app's ASC key is connected in the RevenueHog dashboard (the
  server maps your bundle id to your org through it).
- **Customers show as "unverified"**: expected on simulator. On a physical
  device it usually means the App Attest capability is missing from the app
  target; DEBUG builds tell you loudly at launch.
- **Purchases appear but aren't linked to users**: call
  `identify(userId:)` after login; earlier purchases re-attribute
  automatically.
- **Sandbox purchases**: attribution works in sandbox too; the dashboard
  hides sandbox data unless you enable it in settings.
- **Self-hosting**: point `Options.baseURL` at your deployment; paths are
  `/api/sdk/v1/identify`, `/api/sdk/v1/attribute`, and the two
  `/api/sdk/v1/attest` enrollment endpoints.

## Tests

```sh
cd swift && swift test
```

Queue persistence, payload encoding, retry/backoff, identity aliasing, the
App Attest enrollment state machine, and the entitlement self-check are
covered against mocked transport and attest-service seams. No network, no
device, no Keychain needed.
