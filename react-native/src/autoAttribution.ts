import type { HogClient } from './client';
import type { Logger } from './logger';

export interface IapPurchase {
  transactionId?: string;
  originalTransactionIdentifierIOS?: string;
  productId?: string;
  /** react-native-iap ≥ 13 (StoreKit 2 mode). */
  jwsRepresentationIos?: string;
  /** casing used by some react-native-iap builds */
  jwsRepresentationIOS?: string;
  /** older StoreKit 2 field that also carries the signed transaction */
  verificationResultIOS?: string;
}

interface IapModule {
  purchaseUpdatedListener?: (
    listener: (purchase: IapPurchase) => void
  ) => { remove?: () => void };
}

/**
 * If the host app has `react-native-iap` installed, hook its
 * `purchaseUpdatedListener` and attribute purchases automatically.
 * Completely inert (and silent) when the module is absent. Returns an
 * unsubscribe function.
 */
export function tryHookReactNativeIap(
  client: HogClient,
  log: Logger
): (() => void) | undefined {
  try {
    const mod = require('react-native-iap') as { default?: IapModule } & IapModule;
    const iap = mod?.default?.purchaseUpdatedListener ? mod.default : mod;
    if (typeof iap?.purchaseUpdatedListener !== 'function') return undefined;

    const subscription = iap.purchaseUpdatedListener((purchase) => {
      try {
        const txn =
          purchase?.originalTransactionIdentifierIOS ?? purchase?.transactionId;
        if (!txn) return;
        void client.attributePurchase({
          originalTransactionId: txn,
          productId: purchase?.productId,
          jws: jwsFromPurchase(purchase),
        });
      } catch {
        // never let attribution break the host app's purchase flow
      }
    });
    log.info('auto-attribution: hooked react-native-iap purchaseUpdatedListener');
    return () => {
      try {
        subscription?.remove?.();
      } catch {
        // ignore
      }
    };
  } catch {
    // react-native-iap not installed — auto-attribution silently off
    return undefined;
  }
}

/**
 * StoreKit 2 signed transaction from a react-native-iap purchase, when the
 * installed version exposes it (iOS only). Tolerant of the field-name drift
 * across react-native-iap releases; anything that doesn't look like a JWS
 * (three dot-separated segments) is ignored.
 */
export function jwsFromPurchase(purchase: IapPurchase | undefined): string | undefined {
  const candidate =
    purchase?.jwsRepresentationIos ??
    purchase?.jwsRepresentationIOS ??
    purchase?.verificationResultIOS;
  return typeof candidate === 'string' && candidate.split('.').length === 3
    ? candidate
    : undefined;
}
