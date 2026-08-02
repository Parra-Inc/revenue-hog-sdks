# @revenuehog/react-native

User-level purchase attribution for [RevenueHog](https://revenuehog.dev).
Pure TypeScript/JS, no native code, works in **Expo Go**. Zero runtime
dependencies, ~500 lines.

> **You don't need this SDK to use RevenueHog.** Revenue tracking, the live
> feed, metrics, and push alerts all work server-side from your App Store
> Connect `.p8` key: no SDK, no code changes. Install this SDK only when you
> want *user-level attribution*: knowing which of **your** app users a
> purchase belongs to, plus device/locale context and custom attributes on
> customer profiles.

## Install

```sh
npm install @revenuehog/react-native
```

Optional (auto-detected when present, never required):

- `@react-native-async-storage/async-storage` persists the anonymous id
  and offline queue across relaunches (recommended)
- `expo-application` or `react-native-device-info` auto-detects your
  bundle id and device model
- `react-native-iap` enables automatic purchase attribution

## 60-second quickstart

One required line, at app startup (e.g. top of `App.tsx` or your root layout):

```ts
import RevenueHog from '@revenuehog/react-native';

RevenueHog.configure(); // ← the one line, no key needed
```

When you know who the user is:

```ts
await RevenueHog.identify('user_42');
```

Purchases reported before login (under a persisted anonymous id) are
re-attributed to `user_42` automatically.

### How auth works

There is no API key. The server maps requests to your org by bundle id, and
identity data from this SDK is labeled **unverified** in the RevenueHog
dashboard until attestation support lands (integration with
`expo-app-integrity` is planned). One exception: on iOS, purchases attributed
with a StoreKit 2 signed transaction (`jws`, see below) are verified against
Apple's signature, so the purchase link itself is trusted today.

### Attributing purchases

React Native purchases usually flow through `react-native-iap` or
`expo-in-app-purchases`. Two options:

**Automatic**: if `react-native-iap` is installed and `autoAttribution` is
on (the default), the SDK lazily hooks `purchaseUpdatedListener` and
attributes every purchase, including the StoreKit 2 signed transaction
(`jwsRepresentationIos`) when the installed version exposes it. Nothing to do.

**Manual**: call `attributePurchase` from your own purchase listener:

```ts
// react-native-iap
import { purchaseUpdatedListener } from 'react-native-iap';

purchaseUpdatedListener((purchase) => {
  RevenueHog.attributePurchase({
    originalTransactionId:
      purchase.originalTransactionIdentifierIOS ?? purchase.transactionId!,
    productId: purchase.productId,
    jws: purchase.jwsRepresentationIos, // iOS: Apple-signed transaction
  });
  // …your finishTransaction logic
});

// expo-in-app-purchases
setPurchaseListener(({ results }) => {
  for (const p of results ?? []) {
    RevenueHog.attributePurchase({
      originalTransactionId: p.originalOrderId ?? p.orderId,
      productId: p.productId,
    });
  }
});
```

## API reference

| Call | What it does |
|---|---|
| `RevenueHog.configure(config?)` | Sets up the SDK. Call once at startup. Never throws. |
| `RevenueHog.identify(userId)` | Links the anonymous id (and everything reported under it) to your user id. |
| `RevenueHog.setAttributes(attrs)` | Attaches a flat `Record<string, string>` to the user's profile. |
| `RevenueHog.attributePurchase({ originalTransactionId, productId?, jws? })` | Links a purchase to the current user. `jws` is the StoreKit 2 signed transaction (iOS); when present the server verifies it against Apple's signature and it is sent in the `jws` field of `POST /api/sdk/v1/attribute`. |
| `RevenueHog.reset()` | Forgets the user on logout; issues a fresh anonymous id. |
| `RevenueHog.flush()` | Retries the offline queue (e.g. on connectivity regained). |

### Config

All fields are optional:

```ts
RevenueHog.configure({
  baseUrl: 'https://…',           // self-hosted / dev (default https://revenuehog.dev)
  bundleId: 'com.your.app',       // pass if not auto-detectable
  autoAttribution: true,          // default, hooks react-native-iap when installed
  storage: myStorageAdapter,      // anything with the AsyncStorage shape
  logLevel: 'warn',               // 'debug' | 'info' | 'warn' | 'error' | 'silent'
});
```

`StorageAdapter` is just `{ getItem, setItem, removeItem }` returning
promises: MMKV wrappers, SecureStore, whatever you like.

## When do I need this?

| You want | SDK needed? |
|---|---|
| Revenue feed, MRR, churn, push alerts | **No**, `.p8` server-side ingestion covers it |
| Know *which app user* made a purchase | Yes |
| Device model / OS / locale on customer profiles | Yes |
| Custom attributes (`plan`, `cohort`, …) | Yes |

## Behavior notes

- **Never crashes your app.** All methods swallow errors into the debug log
  and resolve normally. Calling anything before `configure` is a logged no-op.
- **Offline-safe.** Failed requests (network, `429`, `5xx`) retry with
  exponential backoff (max 3 attempts), then persist to a queue (cap 100)
  that flushes on the next call / `flush()` / relaunch.
- **Idempotent.** The API dedupes server-side; the SDK also skips
  transactions already reported for the current user.
- **Private.** Sends only: your user id (or an anonymous UUID), bundle id,
  OS version, device model, locale, attributes you pass, and (iOS) the
  Apple-signed transaction. No IDFA.
- **Unverified until attested.** Requests carry no credentials, so identity
  data from this SDK is labeled unverified in the dashboard until attestation
  support lands. JWS-carrying purchases are transaction-verified regardless.
- **Expo Go friendly.** No native modules. Without async-storage installed it
  falls back to in-memory storage (anonymous id won't survive relaunches:
  fine for development, install async-storage for production).

## Troubleshooting

- **"bundleId not detected" warning**: pass `bundleId` to `configure`, or
  install `expo-application` / `react-native-device-info`.
- **Nothing shows up**: set `logLevel: 'debug'` to watch requests, and check
  the bundle id matches an app in your RevenueHog org.
- **Customer rows labeled unverified**: expected for this SDK today; the
  label clears once attestation support ships.
- **Android purchases**: RevenueHog ingests Apple revenue today. You can
  still `identify` Android users now; pass the Play purchase token as
  `originalTransactionId` and the mapping is stored for future Play support.
- **Self-hosting**: point `baseUrl` at your deployment; paths are
  `/api/sdk/v1/identify` and `/api/sdk/v1/attribute`.

## Tests

```sh
cd react-native && npm install && npm test && npm run build
```

Queueing, payload shapes, retry/backoff, identity aliasing, JWS pass-through,
and never-crash behavior are covered with a mocked `fetch`, no network needed.
