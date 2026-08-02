import { Logger } from './logger';
import { PersistentQueue } from './queue';
import { detectAsyncStorage, memoryStorage } from './storage';
import { detectDevice, type DeviceContext } from './device';
import type {
  AttributePayload,
  AttributePurchaseInput,
  FetchLike,
  IdentifyPayload,
  PendingRequest,
  RevenueHogConfig,
  StorageAdapter,
} from './types';

const IDENTIFY_PATH = '/api/sdk/v1/identify';
const ATTRIBUTE_PATH = '/api/sdk/v1/attribute';
const MAX_ATTEMPTS = 3;

export interface ClientSeams {
  device?: DeviceContext;
  /** ms before retry n (0-indexed). Tests inject `() => 0`. */
  backoffMs?: (attempt: number) => number;
}

export class HogClient {
  private readonly baseUrl: string;
  private readonly storage: StorageAdapter;
  private readonly queue: PersistentQueue;
  private readonly fetchFn: FetchLike;
  private readonly log: Logger;
  private readonly device: DeviceContext;
  private readonly backoffMs: (attempt: number) => number;
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
      await this.storage.setItem('rh_anon_id', freshAnonId());
      await this.queue.clear();
      this.log.info('reset — new anonymous id issued');
    });
  }

  flush(): Promise<void> {
    return this.run(() => this.flushQueue());
  }

  // ── internals ────────────────────────────────────────────────────────────

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
