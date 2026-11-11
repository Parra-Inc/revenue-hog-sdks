export type LogLevel = 'debug' | 'info' | 'warn' | 'error' | 'silent';

/**
 * Anything with the AsyncStorage shape works. The default is
 * `@react-native-async-storage/async-storage` when installed, otherwise an
 * in-memory store (attribution still works; the anonymous id and offline
 * queue just don't survive relaunches).
 */
export interface StorageAdapter {
  getItem(key: string): Promise<string | null>;
  setItem(key: string, value: string): Promise<void>;
  removeItem(key: string): Promise<void>;
}

export interface RevenueHogConfig {
  /** Override for self-hosted deployments or local dev. */
  baseUrl?: string;
  /**
   * Your app's bundle id / application id. Auto-detected via
   * `expo-application` or `react-native-device-info` when installed;
   * pass explicitly otherwise.
   */
  bundleId?: string;
  /**
   * Default `true`: if `react-native-iap` is installed, its
   * `purchaseUpdatedListener` is hooked lazily and purchases are attributed
   * automatically. Never throws if the module is absent.
   */
  autoAttribution?: boolean;
  /** Custom persistence. */
  storage?: StorageAdapter;
  /** Default `'warn'`. */
  logLevel?: LogLevel;
  /**
   * StoreKit environment for paywall experiment health
   * (`'Production' | 'Sandbox' | 'Xcode'`). React Native cannot read
   * AppTransaction, so pass it when you know it (e.g. a TestFlight build
   * config); the server reads an absent value as Production.
   */
  storeEnvironment?: 'Production' | 'Sandbox' | 'Xcode';
  /**
   * Renders the churn survey with your own UI: a function that shows
   * `survey` (options in the given order, "Other" last) and resolves with
   * the user's answer. Leave it out to use the built-in sheet by mounting
   * `<ChurnSurveyHost />`; with neither, `presentChurnSurvey()` resolves
   * `{ type: 'notShown' }`.
   */
  churnSurveyPresenter?: ChurnSurveyPresenter;
  /**
   * Default `true`: on Android with `react-native-iap`, configure() checks
   * the user's subscriptions and shows the survey on the first launch after
   * auto-renew turns off. On iOS call `autoRenewChanged()` yourself.
   */
  churnSurveyAutoTrigger?: boolean;
  /** Test seam — custom fetch implementation. */
  fetch?: FetchLike;
}

export type PaywallSkuKind = 'subscription' | 'iap' | 'unknown';

export interface PaywallSku {
  productId: string;
  kind: PaywallSkuKind;
}

/**
 * The answer to "which SKUs should this paywall offer": an ORDERED list.
 * Render in this order — under an experiment the order is part of what is
 * being tested. Never absent: on any failure it carries the compiled-in
 * fallback with `isFallback: true`.
 */
export interface Paywall {
  entitlement: string;
  skus: PaywallSku[];
  /** The ordered product ids, ready for your store's product loader. */
  productIds: string[];
  /** Present while an A/B experiment is serving this install. */
  experimentId?: string;
  /** This install's variant, for the app's own analytics. */
  variantKey?: string;
  isFallback: boolean;
}

export interface PaywallOptions {
  /**
   * QA preview of a named variant. Honored by the server only for
   * non-Production store environments; never cached, never recorded.
   */
  forceVariant?: string;
}

export interface AttributePurchaseInput {
  /**
   * StoreKit `originalTransactionId` (iOS). On Android, pass the Play
   * purchase token — stored for future Play ingestion.
   */
  originalTransactionId: string;
  productId?: string;
  /**
   * StoreKit 2 signed transaction (`jwsRepresentationIos` on a
   * react-native-iap purchase). When present the server verifies the
   * transaction against Apple's signature, so the purchase link is trusted
   * even before attestation support lands.
   */
  jws?: string;
}

export interface ChurnSurveyOption {
  /** Stable key from the dashboard, e.g. `too_expensive`. */
  key: string;
  /** Localized title to show. */
  title: string;
}

/** The survey to render: options already in display order, "Other" last. */
export interface ChurnSurvey {
  version: number;
  title: string;
  options: ChurnSurveyOption[];
  otherEnabled: boolean;
  otherPlaceholder: string;
  /**
   * Show an optional free-text field that goes with any answer. When false
   * the field is hidden and additional info is never sent.
   */
  allowAdditionalInfo: boolean;
  /** Keys in shown order, "other" last when enabled. Sent with the answer. */
  shownOrder: string[];
}

export type ChurnSurveyResult =
  | { type: 'option'; key: string; additionalInfo?: string }
  | { type: 'other'; text: string; additionalInfo?: string }
  | { type: 'skipped' }
  | { type: 'notShown' };

export type ChurnSurveyPresenter = (survey: ChurnSurvey) => Promise<ChurnSurveyResult>;

export interface PresentChurnSurveyOptions {
  productId?: string;
}

export interface IdentifyPayload {
  appUserId: string;
  bundleId: string;
  platform: 'ios' | 'android';
  osVersion?: string;
  deviceModel?: string;
  locale?: string;
  attributes?: Record<string, string>;
  /** Pre-login `$anon_` id, sent on the first identify so the server merges it. */
  anonymousAppUserId?: string;
}

export interface AttributePayload {
  appUserId: string;
  bundleId: string;
  /** Tells the server which store the id belongs to (Play token vs Apple id). */
  platform?: 'ios' | 'android';
  originalTransactionId: string;
  productId?: string;
  jws?: string;
}

export interface PendingRequest {
  path: string;
  body: string;
}

export type FetchLike = (
  url: string,
  init: {
    method: string;
    headers: Record<string, string>;
    /** Absent on GET (the churn survey config read). */
    body?: string;
  }
  // `text` is optional so old mocks stay valid; the real fetch Response
  // satisfies it structurally. Only the paywall path reads a body.
) => Promise<{ status: number; text?: () => Promise<string> }>;

/** A flat JSON value for event properties and feedback data/metadata. */
export type PropertyValue = string | number | boolean | null;

export type EventProperties = Record<string, PropertyValue>;

export type FeedbackKind = 'bug' | 'idea' | 'question' | 'praise';

export interface FeedbackInput {
  kind: FeedbackKind;
  /** Required, at most 5000 characters (trimmed). */
  message: string;
  /** Optional integer 1 to 5. */
  rating?: number;
  /** Optional small structured payload (max 8 KB of JSON), e.g. a repro blob. */
  data?: Record<string, unknown>;
  /** Optional extra context (max 8 KB of JSON). Device context is added for you. */
  metadata?: Record<string, unknown>;
}

/** Outcome of `sendFeedback`. The promise never rejects. */
export type FeedbackResult =
  | { status: 'sent'; id?: string }
  /** Offline or rate limited: persisted and delivered on a later flush or launch. */
  | { status: 'queued' }
  /** Invalid input, or a request the server will never accept. Not retried. */
  | { status: 'rejected'; reason: string };

export interface AdServicesTokenOptions {
  /** Defaults from `storeEnvironment` in configure(), else `__DEV__` ? 'debug' : 'production'. */
  environment?: 'production' | 'sandbox' | 'debug';
  /** App Store storefront country code, e.g. 'USA'. */
  storefront?: string;
  /** Defaults to the detected app version. */
  appVersion?: string;
}
