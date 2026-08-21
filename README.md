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

- **one required line** at app launch — everything else is optional (no
  API key: iOS proves itself with App Attest, see below)
- persisted anonymous id, so purchases attribute before login;
  `identify(userId)` re-attributes them afterward
- offline/rate-limit safe: exponential backoff (max 3), then a persistent
  queue that flushes later — both endpoints are idempotent
- never crashes the host app: every failure is swallowed into a debug log

## Quickstart — the one line

**Swift** (App init / `didFinishLaunching`):

```swift
RevenueHog.configure()
```

**React Native** (top of your root component/layout):

```ts
RevenueHog.configure();
```

**Android** (`Application.onCreate`):

```kotlin
RevenueHog.configure(this)
```

Then, when a user logs in (same call everywhere, spelled natively):

```
identify("user_42")
```

There is no API key. On iOS the SDK enrolls each install with App Attest:
Apple vouches that the caller is your genuine app, RevenueHog matches it to
your account through the App Store Connect data it already has, and issues
the device a private token. Add the App Attest capability to your app target
and that's it. Calls without attestation (simulator, React Native and
Android today) still work and are labeled unverified in the dashboard.
Self-hosting or developing locally? Every SDK takes a base-URL override in
its configure options.

## Server-driven paywall SKUs

The RevenueHog dashboard can decide WHICH products your paywall offers (and
A/B test the offer set) without an app update. Your app keeps its paywall
UI; the SDK answers with an ordered SKU list and can never come back empty:
fresh cache, then a short network fetch, then stale cache, then the
compiled-in fallback you pass at the call site.

**Swift**:

```swift
let paywall = await RevenueHog.paywall(
    for: "pro", fallback: ["com.example.pro.annual", "com.example.pro.monthly"]
)
let products = try await paywall.products() // loaded AND re-sorted to menu order
// … render …
RevenueHog.paywallShown(paywall, rendered: products.map(\.id))
```

**React Native**:

```ts
const paywall = await RevenueHog.paywall('pro', ['com.example.pro.annual']);
// load paywall.productIds through your IAP library, render in that order
await RevenueHog.paywallShown(paywall, renderedProductIds);
```

**Android** (callback runs on the SDK thread; hop to main before rendering):

```kotlin
RevenueHog.paywall("pro", listOf("com.example.pro.annual")) { paywall ->
    // load paywall.productIds through Play Billing, render in that order
    RevenueHog.paywallShown(paywall, renderedProductIds)
}
```

Rules that are the contract, not suggestions: render in the returned order
(StoreKit's `Product.products(for:)` comes back unordered and the order is
part of what gets tested); call `paywallShown` when the paywall actually
appears, after product loading, so experiments count real exposures; keep
attributing purchases — attribution is what makes an experiment measurable.
The cache invalidates itself on `identify`/`reset`. QA can preview a variant
with the `forceVariant` option (honored only for non-production traffic,
never recorded).

## API contract

All three SDKs speak the same endpoints:

```
POST /api/sdk/v1/attest/challenge   {} -> { challenge }            (iOS enrollment)
POST /api/sdk/v1/attest             { keyId, attestation, challenge, bundleId } -> { deviceToken }
POST /api/sdk/v1/identify   { appUserId, bundleId, platform, osVersion?, deviceModel?, locale?, attributes? }
POST /api/sdk/v1/attribute  { appUserId, bundleId, originalTransactionId, productId?, jws? }
POST /api/sdk/v1/paywall    { appUserId, bundleId, installId, entitlement, environment?, forceVariant? }
                            -> { entitlement, skus: [{ productId, kind }], experimentId?, variantKey?, ttlSeconds }
POST /api/sdk/v1/paywall/impression { bundleId, installId, experimentId, renderedSkus }
Authorization: Bearer dt_…          (enrolled iOS; omitted when unattested)
```

The write endpoints are idempotent. `401` = bad device token (re-enroll
once), `429` = rate limited (backoff + queue). On iOS, `jws` carries the
StoreKit 2 signed transaction so the purchase link verifies even unattested.
`installId` is a per-install UUID the SDK mints and persists (iOS: a
non-synchronizable Keychain item that survives reinstalls) so experiment
assignment sticks to the device; an empty `skus` answer means "render your
compiled-in fallback". On iOS the SDK also sends StoreKit's AppTransaction
environment so TestFlight traffic is visible in experiment results.

## Repo layout

```
swift/           Swift Package "RevenueHog"      — swift test (run at repo root; Package.swift lives there so the repo URL is SPM-installable)
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
