import { Logger } from './logger';
import { PersistentQueue } from './queue';
import { detectAsyncStorage, memoryStorage } from './storage';
import { detectDevice, type DeviceContext } from './device';
import type {
  AttributePayload,
  AttributePurchaseInput,
  FetchLike,
  IdentifyPayload,
  Paywall,
  PaywallOptions,
  PaywallSku,
  PaywallSkuKind,
  PendingRequest,
  RevenueHogConfig,
  StorageAdapter,
} from './types';

const IDENTIFY_PATH = '/api/sdk/v1/identify';
const ATTRIBUTE_PATH = '/api/sdk/v1/attribute';
const PAYWALL_PATH = '/api/sdk/v1/paywall';
const IMPRESSION_PATH = '/api/sdk/v1/paywall/impression';
const MAX_ATTEMPTS = 3;
const PAYWALL_CACHE_KEY = 'rh_paywall_cache';

export interface ClientSeams {
  device?: DeviceContext;
  /** ms before retry n (0-indexed). Tests inject `() => 0`. */
  backoffMs?: (attempt: number) => number;
  /** Deadline for the paywall fetch (the money path resolves fast). */
  paywallTimeoutMs?: number;
}

/** One cached paywall answer, persisted per entitlement. */
interface CachedPaywall {
  entitlement: string;
  skus: PaywallSku[];
  experimentId?: string;
  variantKey?: string;
  ttlSeconds: number;
  fetchedAt: number;
  appUserId: string;
}

function fallbackPaywall(entitlement: string, productIds: string[]): Paywall {
  return {
    entitlement,
    skus: productIds.map((productId) => ({ productId, kind: 'unknown' as const })),
    productIds: [...productIds],
    isFallback: true,
  };
}

export class HogClient {
  private readonly baseUrl: string;
  private readonly storage: StorageAdapter;
  private readonly queue: PersistentQueue;
  private readonly fetchFn: FetchLike;
  private readonly log: Logger;
  private readonly device: DeviceContext;
  private readonly backoffMs: (attempt: number) => number;
  private readonly paywallTimeoutMs: number;
  private readonly storeEnvironment?: string;
  /** serializes all operations so identify/attribute keep their order */
  private ops: Promise<void> = Promise.resolve();

  constructor(config: RevenueHogConfig = {}, seams: ClientSeams = {}) {
    this.baseUrl = (config.baseUrl ?? 'https://revenuehog.dev').replace(/\/+$/, '');
    this.storage = config.storage ?? detectAsyncStorage() ?? memoryStorage();
    this.queue = new PersistentQueue(this.storage);
    this.fetchFn = config.fetch ?? ((url, init) => fetch(url, init));
    this.log = new Logger(config.logLevel ?? 'warn');
    this.device = seams.device ?? detectDevice();
    if (config.bundleId) this.device.bundleId = config.bundleId;
    this.backoffMs = seams.backoffMs ?? ((attempt) => 500 * 2 ** attempt);
    this.paywallTimeoutMs = seams.paywallTimeoutMs ?? 2500;
    this.storeEnvironment = config.storeEnvironment;
    if (!this.device.bundleId) {
      this.log.warn(
        'bundleId not detected — pass { bundleId } to configure() ' +
          '(or install expo-application / react-native-device-info)'
      );
    }
  }

  /** Enqueue an operation; never rejects. */
  private run(work: () => Promise<void>): Promise<void> {
    this.ops = this.ops.then(work).catch((e) => {
      this.log.error(`swallowed: ${e instanceof Error ? e.message : String(e)}`);
    });
    return this.ops;
  }

  identify(userId: string, attributes?: Record<string, string>): Promise<void> {
    return this.run(async () => {
      const trimmed = userId?.trim();
      if (!trimmed) {
        this.log.warn('identify called with empty userId — ignored');
        return;
      }
      const previous = await this.storage.getItem('rh_user_id');
      if (previous !== trimmed) {
        // The appUserId sent on paywall fetches is how purchases join
        // experiment results; a cached answer from the old identity would
        // leave the new one unlinked.
        await this.storage.removeItem(PAYWALL_CACHE_KEY);
      }
      await this.storage.setItem('rh_user_id', trimmed);
      await this.send(IDENTIFY_PATH, await this.identifyPayload(attributes));
      await this.reattributeSentTransactions(trimmed);
      await this.flushQueue();
    });
  }

  setAttributes(attributes: Record<string, string>): Promise<void> {
    return this.run(async () => {
      await this.send(IDENTIFY_PATH, await this.identifyPayload(attributes));
    });
  }

  attributePurchase(input: AttributePurchaseInput): Promise<void> {
    return this.run(() => this.attributeNow(input));
  }

  reset(): Promise<void> {
    return this.run(async () => {
      await this.storage.removeItem('rh_user_id');
      await this.storage.removeItem('rh_sent_txns');
      await this.storage.removeItem(PAYWALL_CACHE_KEY);
      // rh_install_id survives on purpose: it keys experiment assignment
      // to the DEVICE, not to a user.
      await this.storage.setItem('rh_anon_id', freshAnonId());
      await this.queue.clear();
      this.log.info('reset — new anonymous id issued');
    });
  }

  flush(): Promise<void> {
    return this.run(() => this.flushQueue());
  }

  /**
   * Which SKUs this install's paywall should offer, as an ORDERED list the
   * dashboard controls (and can A/B test). Never rejects and never blocks
   * long: fresh cache, then a short network fetch, then stale cache, then
   * the compiled-in `fallback`. Deliberately NOT serialized behind
   * identify/attribute — the money path must not wait for a queue flush.
   */
  async paywall(
    entitlement: string,
    fallback: string[],
    options: PaywallOptions = {}
  ): Promise<Paywall> {
    try {
      return await this.paywallNow(entitlement.trim(), fallback, options);
    } catch (e) {
      this.log.error(
        `paywall failed: ${e instanceof Error ? e.message : String(e)}`
      );
      return fallbackPaywall(entitlement, fallback);
    }
  }

  /**
   * Reports that a paywall actually APPEARED, with the product ids that
   * really rendered. Fetching assigns; impressions expose. No-op outside
   * an experiment. Best-effort and never queued (a replayed impression
   * would count an exposure that may never have happened).
   */
  async paywallShown(paywall: Paywall, rendered: string[]): Promise<void> {
    try {
      if (!paywall.experimentId) return;
      const body = JSON.stringify({
        bundleId: this.device.bundleId ?? 'unknown',
        experimentId: paywall.experimentId,
        installId: await this.installId(),
        renderedSkus: rendered.slice(0, 50),
      });
      await this.deliver(IMPRESSION_PATH, body, 2);
    } catch (e) {
      this.log.debug(
        `paywallShown failed: ${e instanceof Error ? e.message : String(e)}`
      );
    }
  }

  // ── internals ────────────────────────────────────────────────────────────

  private async paywallNow(
    entitlement: string,
    fallback: string[],
    options: PaywallOptions
  ): Promise<Paywall> {
    if (!entitlement) {
      this.log.warn('paywall called with an empty entitlement — serving the fallback');
      return fallbackPaywall(entitlement, fallback);
    }

    const user = await this.appUserId();
    const cache = await this.paywallCache();
    const cached = cache[entitlement];
    const fresh =
      cached &&
      cached.appUserId === user &&
      Date.now() - cached.fetchedAt < cached.ttlSeconds * 1000;
    if (fresh && !options.forceVariant) {
      this.log.debug(`paywall(${entitlement}) served from cache`);
      return this.resolvePaywall(cachedToPaywall(cached), fallback);
    }

    const payload = {
      appUserId: user,
      bundleId: this.device.bundleId ?? 'unknown',
      entitlement,
      installId: await this.installId(),
      ...(this.storeEnvironment ? { environment: this.storeEnvironment } : {}),
      ...(options.forceVariant ? { forceVariant: options.forceVariant } : {}),
    };
    const answer = await this.fetchPaywall(JSON.stringify(payload));
    if (answer) {
      const paywall: Paywall = {
        entitlement: typeof answer.entitlement === 'string' ? answer.entitlement : entitlement,
        skus: wireSkus(answer.skus),
        productIds: wireSkus(answer.skus).map((s) => s.productId),
        ...(typeof answer.experimentId === 'string'
          ? { experimentId: answer.experimentId }
          : {}),
        ...(typeof answer.variantKey === 'string' ? { variantKey: answer.variantKey } : {}),
        isFallback: wireSkus(answer.skus).length === 0,
      };
      // Forced previews are QA-only: never cached, never the real menu.
      if (!options.forceVariant) {
        const ttl = typeof answer.ttlSeconds === 'number' ? answer.ttlSeconds : 3600;
        cache[entitlement] = {
          entitlement: paywall.entitlement,
          skus: paywall.skus,
          ...(paywall.experimentId ? { experimentId: paywall.experimentId } : {}),
          ...(paywall.variantKey ? { variantKey: paywall.variantKey } : {}),
          ttlSeconds: Math.min(Math.max(ttl, 60), 86_400),
          fetchedAt: Date.now(),
          appUserId: user,
        };
        await this.storage.setItem(PAYWALL_CACHE_KEY, JSON.stringify(cache));
      }
      return this.resolvePaywall(paywall, fallback);
    }

    // Network failure: stale beats empty, however old.
    if (cached) {
      this.log.info(`paywall(${entitlement}) network failed — serving stale cache`);
      return this.resolvePaywall(cachedToPaywall(cached), fallback);
    }
    this.log.info(`paywall(${entitlement}) unreachable with no cache — serving the fallback`);
    return fallbackPaywall(entitlement, fallback);
  }

  /** A server answer with SKUs passes through; an empty one becomes the fallback. */
  private resolvePaywall(paywall: Paywall, fallback: string[]): Paywall {
    return paywall.skus.length > 0 ? paywall : fallbackPaywall(paywall.entitlement, fallback);
  }

  /**
   * One UUID per install, persisted so paywall experiment assignment sticks
   * to this device. AsyncStorage survives logout but not reinstall — the
   * documented degraded stickiness vs the iOS Keychain.
   */
  private async installId(): Promise<string> {
    const existing = await this.storage.getItem('rh_install_id');
    if (existing) return existing;
    const fresh = freshAnonId().slice('$anon_'.length).toUpperCase();
    await this.storage.setItem('rh_install_id', fresh);
    return fresh;
  }

  private async paywallCache(): Promise<Record<string, CachedPaywall>> {
    try {
      const raw = await this.storage.getItem(PAYWALL_CACHE_KEY);
      const parsed = raw ? (JSON.parse(raw) as unknown) : {};
      return parsed && typeof parsed === 'object'
        ? (parsed as Record<string, CachedPaywall>)
        : {};
    } catch {
      return {};
    }
  }

  /** One attempt against a short deadline; null on any failure. */
  private async fetchPaywall(body: string): Promise<Record<string, unknown> | null> {
    try {
      const request = this.fetchFn(`${this.baseUrl}${PAYWALL_PATH}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body,
      });
      const res = await Promise.race([
        request,
        sleep(this.paywallTimeoutMs).then(() => null),
      ]);
      if (!res || res.status < 200 || res.status >= 300) {
        if (res) this.log.warn(`${res.status} from ${PAYWALL_PATH}`);
        return null;
      }
      if (typeof res.text !== 'function') return null;
      const parsed = JSON.parse(await res.text()) as unknown;
      return parsed && typeof parsed === 'object'
        ? (parsed as Record<string, unknown>)
        : null;
    } catch (e) {
      this.log.debug(
        `network error on ${PAYWALL_PATH}: ${e instanceof Error ? e.message : String(e)}`
      );
      return null;
    }
  }

  private async appUserId(): Promise<string> {
    const user = await this.storage.getItem('rh_user_id');
    if (user) return user;
    const anon = await this.storage.getItem('rh_anon_id');
    if (anon) return anon;
    const fresh = freshAnonId();
    await this.storage.setItem('rh_anon_id', fresh);
    return fresh;
  }

  private async identifyPayload(
    attributes?: Record<string, string>
  ): Promise<IdentifyPayload> {
    return {
      appUserId: await this.appUserId(),
      bundleId: this.device.bundleId ?? 'unknown',
      platform: this.device.platform,
      ...(this.device.osVersion ? { osVersion: this.device.osVersion } : {}),
      ...(this.device.deviceModel ? { deviceModel: this.device.deviceModel } : {}),
      ...(this.device.locale ? { locale: this.device.locale } : {}),
      ...(attributes ? { attributes } : {}),
    };
  }

  private async attributeNow(input: AttributePurchaseInput): Promise<void> {
    const txn = input.originalTransactionId?.trim();
    if (!txn) {
      this.log.warn('attributePurchase called without originalTransactionId — ignored');
      return;
    }
    const user = await this.appUserId();
    const sent = await this.sentTransactions();
    if (sent[txn] === user) {
      this.log.debug(`txn ${txn} already attributed to ${user} — skipped`);
      return;
    }
    sent[txn] = user;
    await this.storage.setItem('rh_sent_txns', JSON.stringify(sent));
    const payload: AttributePayload = {
      appUserId: user,
      bundleId: this.device.bundleId ?? 'unknown',
      platform: this.device.platform,
      originalTransactionId: txn,
      ...(input.productId ? { productId: input.productId } : {}),
      ...(input.jws ? { jws: input.jws } : {}),
    };
    await this.send(ATTRIBUTE_PATH, payload);
  }

  private async sentTransactions(): Promise<Record<string, string>> {
    try {
      const raw = await this.storage.getItem('rh_sent_txns');
      const parsed = raw ? (JSON.parse(raw) as unknown) : {};
      return parsed && typeof parsed === 'object'
        ? (parsed as Record<string, string>)
        : {};
    } catch {
      return {};
    }
  }

  private async reattributeSentTransactions(userId: string): Promise<void> {
    const sent = await this.sentTransactions();
    for (const [txn, sentAs] of Object.entries(sent)) {
      if (sentAs !== userId) {
        await this.attributeNow({ originalTransactionId: txn });
      }
    }
  }

  private async send(path: string, payload: unknown): Promise<void> {
    const body = JSON.stringify(payload);
    if (await this.deliver(path, body, MAX_ATTEMPTS)) {
      await this.flushQueue();
    } else {
      await this.queue.append({ path, body });
      this.log.info(`queued ${path} for later delivery`);
    }
  }

  private async flushQueue(): Promise<void> {
    let pending = await this.queue.load();
    if (pending.length === 0) return;
    this.log.debug(`flushing ${pending.length} queued request(s)`);
    while (pending.length > 0) {
      const item = pending[0] as PendingRequest;
      if (!(await this.deliver(item.path, item.body, 1))) break;
      pending = pending.slice(1);
    }
    await this.queue.save(pending);
  }

  /**
   * True when delivered — or permanently rejected (a request the server
   * will never accept is dropped, not retried forever).
   */
  private async deliver(path: string, body: string, attempts: number): Promise<boolean> {
    for (let attempt = 0; attempt < attempts; attempt++) {
      try {
        const res = await this.fetchFn(`${this.baseUrl}${path}`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body,
        });
        if (res.status >= 200 && res.status < 300) return true;
        if (res.status === 429 || res.status >= 500) {
          this.log.warn(`${res.status} from ${path} — backing off`);
        } else {
          this.log.error(`${res.status} from ${path} — dropped`);
          return true;
        }
      } catch (e) {
        this.log.debug(
          `network error on ${path}: ${e instanceof Error ? e.message : String(e)}`
        );
      }
      if (attempt < attempts - 1) await sleep(this.backoffMs(attempt));
    }
    return false;
  }
}

function cachedToPaywall(cached: CachedPaywall): Paywall {
  return {
    entitlement: cached.entitlement,
    skus: cached.skus,
    productIds: cached.skus.map((s) => s.productId),
    ...(cached.experimentId ? { experimentId: cached.experimentId } : {}),
    ...(cached.variantKey ? { variantKey: cached.variantKey } : {}),
    isFallback: cached.skus.length === 0,
  };
}

const SKU_KINDS: PaywallSkuKind[] = ['subscription', 'iap'];

/** Lenient wire decode: unknown kinds pass through as 'unknown', junk drops. */
function wireSkus(raw: unknown): PaywallSku[] {
  if (!Array.isArray(raw)) return [];
  const out: PaywallSku[] = [];
  for (const row of raw) {
    if (!row || typeof row !== 'object') continue;
    const { productId, kind } = row as Record<string, unknown>;
    if (typeof productId !== 'string' || productId.length === 0) continue;
    out.push({
      productId,
      kind: SKU_KINDS.includes(kind as PaywallSkuKind)
        ? (kind as PaywallSkuKind)
        : 'unknown',
    });
  }
  return out;
}

function freshAnonId(): string {
  const uuid =
    typeof crypto !== 'undefined' && crypto && typeof crypto.randomUUID === 'function'
      ? crypto.randomUUID()
      : fallbackUuid();
  return `$anon_${uuid.toLowerCase()}`;
}

function fallbackUuid(): string {
  let out = '';
  for (const c of 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx') {
    if (c === 'x' || c === 'y') {
      const r = (Math.random() * 16) | 0;
      out += (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
    } else {
      out += c;
    }
  }
  return out;
}

function sleep(ms: number): Promise<void> {
  return ms <= 0
    ? Promise.resolve()
    : new Promise((resolve) => setTimeout(resolve, ms));
}
