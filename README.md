# revenuehog sdks

Client SDKs for [RevenueHog](https://revenuehog.dev) — know the second you
get paid. RevenueHog watches your App Store revenue server-side and turns it
into a live feed, metrics, customer profiles, and push alerts.

## You don't need an SDK

Read this part first. **RevenueHog works fully without any SDK installed.**
Drop your App Store Connect `.p8` key in the dashboard and the server does
all the work: transaction backfill via the App Store Server API, real-time
server-to-server notifications, the live feed, MRR/churn metrics, and push
alerts. No code changes, no release, no SDK.

These SDKs are **optional add-ons** that unlock *user-level attribution*:

- know **which of your app users** a purchase belongs to (instead of an
  anonymized `customer_8f3c` derived from the transaction)
- device context on customer profiles — OS version, device model, locale
- custom attributes (`plan`, `cohort`, whatever you like)

Nothing more. No IDFA, no fingerprinting, no receipt uploads, no revenue
logic in the client. If an SDK is offline or absent, your revenue data is
untouched — you just see anonymized customers.

## The SDKs

| | Package | Platform | Purchases | Size |
|---|---|---|---|---|
| [`swift/`](swift/) | `RevenueHog` (SwiftPM) | iOS 15+ (tvOS, watchOS, macOS too) | automatic via StoreKit 2 | ~500 LOC, zero deps |
| [`react-native/`](react-native/) | `@revenuehog/react-native` (npm) | React Native / Expo (pure JS, Expo Go OK) | auto via `react-native-iap` when installed, or one manual call | ~500 LOC, zero deps |
| [`kotlin/`](kotlin/) | `com.revenuehog:revenuehog-android` (Maven) | Android, minSdk 24 | identity parity today; Play mapping stored for future Play ingestion | ~500 LOC, zero deps |

Shared behavior, all three:

- **one required line** at app launch — everything else is optional
- persisted anonymous id, so purchases attribute before login;
  `identify(userId)` re-attributes them afterward
- offline/rate-limit safe: exponential backoff (max 3), then a persistent
  queue that flushes later — both endpoints are idempotent
- never crashes the host app: every failure is swallowed into a debug log

## Quickstart — the one line

**Swift** (App init / `didFinishLaunching`):

```swift
RevenueHog.configure(apiKey: "pk_live_…")
```

**React Native** (top of your root component/layout):

```ts
RevenueHog.configure({ apiKey: 'pk_live_…' });
```

**Android** (`Application.onCreate`):

```kotlin
RevenueHog.configure(this, "pk_live_…")
```

Then, when a user logs in (same call everywhere, spelled natively):

```
identify("user_42")
```

Your publishable key (`pk_live_…`) lives in the dashboard → settings → API.
It's write-only for attribution data and safe to ship in a client binary.
Self-hosting or developing locally? Every SDK takes a base-URL override in
its configure options.

## API contract

All three SDKs speak the same two endpoints:

```
POST /api/sdk/v1/identify   { appUserId, bundleId, platform, osVersion?, deviceModel?, locale?, attributes? }
POST /api/sdk/v1/attribute  { appUserId, bundleId, originalTransactionId, productId? }
Authorization: Bearer pk_live_…
```

Both idempotent. `401` = bad key (dropped), `429` = rate limited (backoff +
queue).

## Repo layout

```
swift/           Swift Package "RevenueHog"      — swift test
react-native/    @revenuehog/react-native        — npm test && npm run build
kotlin/          com.revenuehog:revenuehog-android — ./gradlew test
```

Each directory has its own README with install, full API reference, a
"when do I need this?" table, and troubleshooting.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: zero runtime deps,
never crash the host, keep it under ~500 lines, bring tests.

## License

[MIT](LICENSE) © Parra, Inc.
