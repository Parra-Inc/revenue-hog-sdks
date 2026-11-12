import { HogClient } from './client';
import { Logger } from './logger';
import { tryHookReactNativeIap, tryReadAndroidRenewals } from './autoAttribution';
import { builtInChurnSurveyPresenter, isChurnSurveyHostMounted } from './ChurnSurveySheet';
import type {
  AdServicesTokenOptions,
  AttributePurchaseInput,
  EventProperties,
  FeedbackInput,
  FeedbackKind,
  FeedbackResult,
  PropertyValue,
  ChurnSurvey,
  ChurnSurveyOption,
  ChurnSurveyPresenter,
  ChurnSurveyResult,
  PresentChurnSurveyOptions,
  LogLevel,
  Paywall,
  PaywallOptions,
  PaywallSku,
  PaywallSkuKind,
  RevenueHogConfig,
  StorageAdapter,
} from './types';

let client: HogClient | undefined;
let unhookIap: (() => void) | undefined;
let presenter: ChurnSurveyPresenter | undefined;

async function presentWith(
  c: HogClient,
  automatic: boolean,
  productId: string | undefined
): Promise<ChurnSurveyResult> {
  const show = presenter ?? (isChurnSurveyHostMounted() ? builtInChurnSurveyPresenter : undefined);
  if (!show) {
    if (!automatic) {
      new Logger('warn').warn(
        'presentChurnSurvey needs <ChurnSurveyHost /> mounted or a churnSurveyPresenter in configure()'
      );
    }
    return { type: 'notShown' };
  }
  const survey = await c.churnSurvey(automatic);
  if (!survey) return { type: 'notShown' };
  await c.churnSurveyShown();
  let result: ChurnSurveyResult;
  try {
    result = await show(survey);
  } catch {
    result = { type: 'skipped' };
  }
  await c.submitChurnSurvey(survey, result, productId);
  return result;
}

async function autoRenewOff(
  c: HogClient,
  renewals: { originalId: string; productId?: string; willAutoRenew: boolean }[]
): Promise<void> {
  const fresh = await c.claimNewlyCancelled(renewals);
  if (!fresh) return;
  const productId = renewals.find((r) => r.originalId === fresh)?.productId;
  const result = await presentWith(c, true, productId);
  if (result.type !== 'notShown') await c.markChurnHandled(fresh);
}

function withClient(name: string, work: (c: HogClient) => Promise<void>): Promise<void> {
  if (!client) {
    new Logger('warn').warn(
      `${name} called before configure — call RevenueHog.configure() first`
    );
    return Promise.resolve();
  }
  return work(client);
}

/**
 * RevenueHog user-level attribution. One required line at app startup:
 *
 * ```ts
 * RevenueHog.configure();
 * ```
 *
 * No API key: requests are unauthenticated and the server labels the
 * resulting identity data unverified until attestation support lands.
 * RevenueHog's revenue tracking works entirely server-side without this SDK
 * — install it only for user-level attribution.
 */
export const RevenueHog = {
  /** Set up the SDK. Call once at app startup. Never throws. */
  configure(config: RevenueHogConfig = {}): void {
    try {
      unhookIap?.();
      unhookIap = undefined;
      client = new HogClient(config);
      presenter = config.churnSurveyPresenter;
      void client.flush();
      void client.sendDailyOpen();
      if (config.churnSurveyAutoTrigger !== false) {
        const c = client;
        void tryReadAndroidRenewals().then((renewals) =>
          renewals.length > 0 ? autoRenewOff(c, renewals) : undefined
        );
      }
      if (config.autoAttribution !== false) {
        unhookIap = tryHookReactNativeIap(
          client,
          new Logger(config.logLevel ?? 'warn')
        );
      }
    } catch (e) {
      new Logger('error').error(
        `configure failed: ${e instanceof Error ? e.message : String(e)}`
      );
    }
  },

  /**
   * Tell RevenueHog who this user is. Purchases reported before this call
   * (under the persisted anonymous id) are re-attributed to `userId`.
   */
  identify(userId: string): Promise<void> {
    return withClient('identify', (c) => c.identify(userId));
  },

  /** Attach flat string key/values to the current user's profile. */
  setAttributes(attributes: Record<string, string>): Promise<void> {
    return withClient('setAttributes', (c) => c.setAttributes(attributes));
  },

  /**
   * Link a purchase to the current user. Call from your purchase flow's
   * success handler (e.g. react-native-iap's `purchaseUpdatedListener`)
   * when auto-attribution is off or unavailable.
   */
  attributePurchase(input: AttributePurchaseInput): Promise<void> {
    return withClient('attributePurchase', (c) => c.attributePurchase(input));
  },

  /**
   * Show the churn survey now, through your `churnSurveyPresenter` or, when
   * there is none, the built-in sheet of a mounted `<ChurnSurveyHost />`. Call it
   * right before opening subscription management. Respects the dashboard
   * switch, sampling and the once-per-90-days cap; resolves
   * `{ type: 'notShown' }` when any of them says no. The answer (or the
   * skip) is recorded automatically. Never rejects.
   */
  presentChurnSurvey(options: PresentChurnSurveyOptions = {}): Promise<ChurnSurveyResult> {
    if (!client) {
      new Logger('warn').warn('presentChurnSurvey called before configure');
      return Promise.resolve({ type: 'notShown' });
    }
    return presentWith(client, false, options.productId).catch(() => ({ type: 'notShown' as const }));
  },

  /**
   * Tell the SDK that auto-renew is off for a subscription (for example from
   * your iOS renewal info). The survey shows once per cancellation, the first
   * time this is called after auto-renew turned off. Pass
   * `willAutoRenew: true` when it is back on so a later cancel asks again.
   */
  autoRenewChanged(input: {
    originalTransactionId: string;
    productId?: string;
    willAutoRenew: boolean;
  }): Promise<void> {
    return withClient('autoRenewChanged', (c) =>
      autoRenewOff(c, [
        {
          originalId: input.originalTransactionId,
          productId: input.productId,
          willAutoRenew: input.willAutoRenew,
        },
      ]).catch(() => undefined)
    );
  },

  /**
   * This install's id: an uppercase UUID string (for example
   * `6F1C2A9E-1B7D-4E0A-9C3F-2D5B8A7E4C10`), minted on first use and kept
   * across logout and `reset()`. Pass it to StoreKit as `appAccountToken`
   * so App Store notifications join this install. Rejects when called
   * before `configure()`.
   */
  getInstallId(): Promise<string> {
    if (!client) {
      return Promise.reject(
        new Error('getInstallId called before configure: call RevenueHog.configure() first')
      );
    }
    return client.installId();
  },

  /** Forget the current user (call on logout); issues a fresh anonymous id. */
  reset(): Promise<void> {
    return withClient('reset', (c) => c.reset());
  },

  /**
   * Send buffered events and retry anything sitting in the offline queue
   * (e.g. on connectivity regained or when the app backgrounds).
   */
  flush(): Promise<void> {
    return withClient('flush', (c) => c.flush());
  },

  /**
   * Record a funnel milestone such as `onboarding_completed`. Names are
   * snake_case, start with a letter, at most 48 characters, and may not
   * start with `rh_` (invalid names are dropped with a warning). Properties
   * are a small flat map (2 KB of JSON at most). Events are persisted and
   * sent in batches of up to 50: when 20 are waiting, about 10 seconds after
   * the first, on `flush()`, and on the next launch. The reserved name
   * `onboarding_step` with `{ step, index }` feeds the onboarding funnel.
   */
  track(name: string, properties?: EventProperties): Promise<void> {
    return withClient('track', (c) => c.track(name, properties));
  },

  /**
   * Send in-app feedback (bug, idea, question or praise) attributed to the
   * current user, with device context added to `metadata`. Never rejects:
   * resolves `{ status: 'sent', id? }`, `{ status: 'queued' }` (offline; it
   * is persisted and delivered later) or `{ status: 'rejected', reason }`.
   */
  sendFeedback(input: FeedbackInput): Promise<FeedbackResult> {
    if (!client) {
      new Logger('warn').warn('sendFeedback called before configure');
      return Promise.resolve({ status: 'rejected', reason: 'not configured' });
    }
    return client
      .sendFeedback(input)
      .catch((): FeedbackResult => ({ status: 'rejected', reason: 'internal error' }));
  },

  /**
   * iOS only: store the Apple Ads attribution token from
   * `AAAttribution.attributionToken()` so RevenueHog can resolve which Apple
   * Ads campaign produced this install. This SDK is pure JS and cannot read
   * the token itself; get it from a small native module (see the README)
   * and pass it here once at launch. Sent once per install; later calls are
   * no-ops. Ignored on Android.
   */
  sendAdServicesToken(token: string, options?: AdServicesTokenOptions): Promise<void> {
    return withClient('sendAdServicesToken', (c) => c.sendAdServicesToken(token, options));
  },

  /**
   * Which SKUs this install's paywall should offer for `entitlement`, as an
   * ORDERED list the RevenueHog dashboard controls (and can A/B test)
   * without an app update. Never rejects: fresh cache, then a short network
   * fetch, then stale cache, then your compiled-in `fallback` list — the
   * paywall is the money path and can never come back empty. Call it when
   * the paywall is about to show, render the SKUs in the returned order,
   * and call `paywallShown` once it is on screen.
   */
  paywall(
    entitlement: string,
    fallback: string[],
    options?: PaywallOptions
  ): Promise<Paywall> {
    if (!client) {
      new Logger('warn').warn(
        'paywall called before configure — serving the compiled-in fallback'
      );
      return Promise.resolve({
        entitlement,
        skus: fallback.map((productId) => ({ productId, kind: 'unknown' as const })),
        productIds: [...fallback],
        isFallback: true,
      });
    }
    return client.paywall(entitlement, fallback, options);
  },

  /**
   * Report that a paywall actually APPEARED, with the product ids that
   * really rendered (after store product loading). Keeps prefetched-but-
   * never-shown paywalls out of experiment denominators and surfaces a
   * variant whose SKU failed to load as a broken test. No-op outside an
   * experiment.
   */
  paywallShown(paywall: Paywall, rendered: string[]): Promise<void> {
    return withClient('paywallShown', (c) => c.paywallShown(paywall, rendered));
  },
};

export default RevenueHog;
export { HogClient } from './client';
export { memoryStorage } from './storage';
export {
  ChurnSurveyHost,
  ChurnSurveySheet,
  builtInChurnSurveyPresenter,
} from './ChurnSurveySheet';
export type {
  ChurnSurveyElement,
  ChurnSurveyHostProps,
  ChurnSurveySheetProps,
} from './ChurnSurveySheet';
export { churnSurveyLabels } from './churnSurveyLabels';
export type { ChurnSurveyLabels } from './churnSurveyLabels';
export { validEventName } from './client';
export type {
  AdServicesTokenOptions,
  AttributePurchaseInput,
  EventProperties,
  FeedbackInput,
  FeedbackKind,
  FeedbackResult,
  PropertyValue,
  ChurnSurvey,
  ChurnSurveyOption,
  ChurnSurveyPresenter,
  ChurnSurveyResult,
  PresentChurnSurveyOptions,
  LogLevel,
  Paywall,
  PaywallOptions,
  PaywallSku,
  PaywallSkuKind,
  RevenueHogConfig,
  StorageAdapter,
};
