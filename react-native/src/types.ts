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
  /** Publishable key from dashboard → settings → API (`pk_live_…`). */
  apiKey: string;
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
  /** Test seam — custom fetch implementation. */
  fetch?: FetchLike;
}

export interface AttributePurchaseInput {
  /**
   * StoreKit `originalTransactionId` (iOS). On Android, pass the Play
   * purchase token — stored for future Play ingestion.
   */
  originalTransactionId: string;
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
}

export interface AttributePayload {
  appUserId: string;
  bundleId: string;
  originalTransactionId: string;
  productId?: string;
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
    body: string;
  }
) => Promise<{ status: number }>;
