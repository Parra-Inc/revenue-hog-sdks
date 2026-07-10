import { HogClient } from './client';
import { Logger } from './logger';
import { tryHookReactNativeIap } from './autoAttribution';
import type {
  AttributePurchaseInput,
  LogLevel,
  RevenueHogConfig,
  StorageAdapter,
} from './types';

let client: HogClient | undefined;
let unhookIap: (() => void) | undefined;

function withClient(name: string, work: (c: HogClient) => Promise<void>): Promise<void> {
  if (!client) {
    new Logger('warn').warn(
      `${name} called before configure — call RevenueHog.configure({ apiKey }) first`
    );
    return Promise.resolve();
  }
  return work(client);
}

/**
 * RevenueHog user-level attribution. One required line at app startup:
 *
 * ```ts
 * RevenueHog.configure({ apiKey: 'pk_live_…' });
 * ```
 *
 * RevenueHog's revenue tracking works entirely server-side without this SDK
 * — install it only for user-level attribution.
 */
export const RevenueHog = {
  /** Set up the SDK. Call once at app startup. Never throws. */
  configure(config: RevenueHogConfig): void {
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
};

export default RevenueHog;
export { HogClient } from './client';
export { memoryStorage } from './storage';
export type {
  AttributePurchaseInput,
  LogLevel,
  RevenueHogConfig,
  StorageAdapter,
};
