import type { HogClient } from './client';
import type { Logger } from './logger';

interface IapPurchase {
  transactionId?: string;
  originalTransactionIdentifierIOS?: string;
  productId?: string;
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
