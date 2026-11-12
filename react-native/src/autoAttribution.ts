import type { HogClient } from './client';
import type { Logger } from './logger';

/**
 * The purchase fields RevenueHog reads, across react-native-iap 12 to 15.
 * Values may be null in 15 (its generated types use `string | null`).
 *
 * - 12/13: iOS `transactionId` + `originalTransactionIdentifierIOS`, StoreKit 2
 *   JWS in `jwsRepresentationIos` (or `verificationResultIOS`); Android
 *   `purchaseToken` (older builds: `purchaseTokenAndroid`).
 * - 14/15: unified `id` plus `platform: 'ios' | 'android'`; on iOS the JWS
 *   moved into the unified `purchaseToken`, on Android `purchaseToken` is the
 *   Play token. `productId` is stable across all of them.
 */
export interface IapPurchase {
  /** react-native-iap 14+: the transaction id (iOS) or order id (Android). */
  id?: string | null;
  transactionId?: string | null;
  originalTransactionIdentifierIOS?: string | null;
  /**
   * Android: the Play purchase token (react-native-iap >= 12).
   * iOS on react-native-iap 14+: the StoreKit 2 signed transaction (JWS).
   */
  purchaseToken?: string | null;
  /** Android: the same token under its older react-native-iap name. */
  purchaseTokenAndroid?: string | null;
  productId?: string | null;
  /** react-native-iap 14+: which store produced the purchase. */
  platform?: string | null;
  /** react-native-iap 13 (StoreKit 2 mode). */
  jwsRepresentationIos?: string | null;
  /** casing used by some react-native-iap builds */
  jwsRepresentationIOS?: string | null;
  /** older StoreKit 2 field that also carries the signed transaction */
  verificationResultIOS?: string | null;
  autoRenewingAndroid?: boolean | null;
  /** react-native-iap 14+ (both platforms). */
  isAutoRenewing?: boolean | null;
}

interface IapModule {
  getAvailablePurchases?: () => Promise<unknown[]>;
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
    const platformOS = currentPlatformOS();
    const mod = require('react-native-iap') as { default?: IapModule } & IapModule;
    const iap = mod?.default?.purchaseUpdatedListener ? mod.default : mod;
    if (typeof iap?.purchaseUpdatedListener !== 'function') return undefined;

    const subscription = iap.purchaseUpdatedListener((purchase) => {
      try {
        const txn = transactionIdFromPurchase(purchase, platformOS);
        if (!txn) return;
        void client.attributePurchase({
          originalTransactionId: txn,
          productId: purchase?.productId ?? undefined,
          jws: jwsFromPurchase(purchase, platformOS),
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

/** `Platform.OS` from react-native, or undefined outside React Native. */
function currentPlatformOS(): string | undefined {
  try {
    const rn = require('react-native') as { Platform?: { OS?: string } } | undefined;
    return rn?.Platform?.OS;
  } catch {
    return undefined;
  }
}

function str(value: string | null | undefined): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined;
}

/**
 * True when `value` looks like a compact JWS: three base64url segments with a
 * JSON header (`eyJ` is base64url for `{"`). Play purchase tokens never match.
 */
export function looksLikeJws(value: string | null | undefined): value is string {
  if (typeof value !== 'string') return false;
  const parts = value.split('.');
  return (
    parts.length === 3 &&
    parts[0]!.startsWith('eyJ') &&
    parts.every((part) => /^[A-Za-z0-9_-]+$/.test(part))
  );
}

/**
 * Which store a purchase came from. react-native-iap 14+ says so in
 * `platform`; older shapes are told apart by their platform-suffixed fields,
 * then by the JS runtime's `Platform.OS`.
 */
function purchasePlatform(
  purchase: IapPurchase | undefined,
  platformOS: string | undefined
): 'ios' | 'android' | undefined {
  const declared = purchase?.platform?.toLowerCase();
  if (declared === 'ios' || declared === 'android') return declared;
  if (
    str(purchase?.originalTransactionIdentifierIOS) ||
    str(purchase?.jwsRepresentationIos) ||
    str(purchase?.jwsRepresentationIOS) ||
    str(purchase?.verificationResultIOS)
  ) {
    return 'ios';
  }
  if (str(purchase?.purchaseTokenAndroid) || typeof purchase?.autoRenewingAndroid === 'boolean') {
    return 'android';
  }
  if (platformOS === 'ios' || platformOS === 'android') return platformOS;
  if (looksLikeJws(purchase?.purchaseToken)) return 'ios';
  return str(purchase?.purchaseToken) ? 'android' : undefined;
}

/**
 * The id RevenueHog links a purchase by. On iOS, the original transaction id
 * (falling back to the transaction id). On Android, the Play purchase token:
 * stable across renewals and the key Google Play's notifications carry.
 * react-native-iap's Android `transactionId` / `id` is the ORDER id, which
 * changes with every renewal, so it would never join the subscription's
 * events. On iOS with react-native-iap 14+, `purchaseToken` is the JWS, never
 * an id.
 */
export function transactionIdFromPurchase(
  purchase: IapPurchase | undefined,
  platformOS?: string
): string | undefined {
  const fallback = str(purchase?.transactionId) ?? str(purchase?.id);
  if (purchasePlatform(purchase, platformOS) === 'android') {
    return str(purchase?.purchaseToken) ?? str(purchase?.purchaseTokenAndroid) ?? fallback;
  }
  return str(purchase?.originalTransactionIdentifierIOS) ?? fallback;
}

/**
 * StoreKit 2 signed transaction from a react-native-iap purchase (iOS only).
 * Prefers the dedicated JWS fields of react-native-iap 13; on 14+ the JWS is
 * the unified `purchaseToken`. Anything that does not look like a JWS is
 * ignored.
 */
export function jwsFromPurchase(
  purchase: IapPurchase | undefined,
  platformOS?: string
): string | undefined {
  for (const candidate of [
    purchase?.jwsRepresentationIos,
    purchase?.jwsRepresentationIOS,
    purchase?.verificationResultIOS,
  ]) {
    if (looksLikeJws(candidate)) return candidate;
  }
  if (purchasePlatform(purchase, platformOS) !== 'ios') return undefined;
  return looksLikeJws(purchase?.purchaseToken) ? purchase!.purchaseToken! : undefined;
}

/**
 * Android only: auto-renew state of the user's current subscriptions via
 * react-native-iap's `getAvailablePurchases()` (`autoRenewingAndroid`). Empty
 * on iOS, where the module does not expose renewal info, and whenever the
 * module is absent or throws.
 */
export async function tryReadAndroidRenewals(): Promise<
  { originalId: string; productId?: string; willAutoRenew: boolean }[]
> {
  try {
    const mod = require('react-native-iap') as { default?: IapModule } & IapModule;
    const iap = mod?.default?.getAvailablePurchases ? mod.default : mod;
    if (typeof iap?.getAvailablePurchases !== 'function') return [];
    return renewalsFromPurchases(await iap.getAvailablePurchases());
  } catch {
    return [];
  }
}

/** Purchases carrying `autoRenewingAndroid` become renewal states. */
export function renewalsFromPurchases(
  purchases: unknown[]
): { originalId: string; productId?: string; willAutoRenew: boolean }[] {
  const out: { originalId: string; productId?: string; willAutoRenew: boolean }[] = [];
  for (const p of Array.isArray(purchases) ? purchases : []) {
    if (!p || typeof p !== 'object') continue;
    const row = p as IapPurchase;
    // react-native-iap 15 still sets autoRenewingAndroid; isAutoRenewing is
    // the unified fallback, trusted only on a purchase marked Android.
    const willAutoRenew =
      typeof row.autoRenewingAndroid === 'boolean'
        ? row.autoRenewingAndroid
        : row.platform === 'android' && typeof row.isAutoRenewing === 'boolean'
          ? row.isAutoRenewing
          : undefined;
    if (willAutoRenew === undefined) continue;
    const id = str(row.purchaseToken) ?? str(row.purchaseTokenAndroid);
    if (!id) continue;
    out.push({ originalId: id, productId: str(row.productId), willAutoRenew });
  }
  return out;
}
