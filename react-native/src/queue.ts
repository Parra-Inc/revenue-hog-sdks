import type { PendingRequest, StorageAdapter } from './types';

const KEY = 'rh_queue';
const MAX = 100;

/**
 * FIFO queue of undelivered requests, persisted through the storage
 * adapter. Both API endpoints are idempotent, so replays are safe.
 */
export class PersistentQueue {
  constructor(private readonly storage: StorageAdapter) {}

  async load(): Promise<PendingRequest[]> {
    try {
      const raw = await this.storage.getItem(KEY);
      if (!raw) return [];
      const parsed = JSON.parse(raw) as unknown;
      return Array.isArray(parsed) ? (parsed as PendingRequest[]) : [];
    } catch {
      return [];
    }
  }

  async save(items: PendingRequest[]): Promise<void> {
    try {
      if (items.length === 0) await this.storage.removeItem(KEY);
      else await this.storage.setItem(KEY, JSON.stringify(items));
    } catch {
      // storage failed — drop silently, never crash the host
    }
  }

  /** Appends, dropping the oldest entries beyond the cap. */
  async append(item: PendingRequest): Promise<void> {
    const items = await this.load();
    items.push(item);
    await this.save(items.slice(-MAX));
  }

  async clear(): Promise<void> {
    await this.save([]);
  }
}
