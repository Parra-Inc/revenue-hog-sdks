import { HogClient } from './client';
import { Logger } from './logger';
import { tryHookReactNativeIap } from './autoAttribution';
import type {
  AttributePurchaseInput,
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
      void client.flush();
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

  /** Forget the current user (call on logout); issues a fresh anonymous id. */
  reset(): Promise<void> {
    return withClient('reset', (c) => c.reset());
  },

  /** Retry anything sitting in the offline queue (e.g. on connectivity regained). */
  flush(): Promise<void> {
    return withClient('flush', (c) => c.flush());
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
export type {
  AttributePurchaseInput,
  LogLevel,
  Paywall,
  PaywallOptions,
  PaywallSku,
  PaywallSkuKind,
  RevenueHogConfig,
  StorageAdapter,
};
