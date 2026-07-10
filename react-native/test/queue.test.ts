import { describe, expect, it } from 'vitest';
import { PersistentQueue } from '../src/queue';
import { memoryStorage } from '../src/storage';

describe('PersistentQueue', () => {
  it('round-trips appended items in FIFO order', async () => {
    const queue = new PersistentQueue(memoryStorage());
    await queue.append({ path: '/a', body: '1' });
    await queue.append({ path: '/b', body: '2' });

    expect(await queue.load()).toEqual([
      { path: '/a', body: '1' },
      { path: '/b', body: '2' },
    ]);
  });

  it('persists through the shared storage adapter', async () => {
    const storage = memoryStorage();
    await new PersistentQueue(storage).append({ path: '/a', body: '1' });

    expect(await new PersistentQueue(storage).load()).toEqual([
      { path: '/a', body: '1' },
    ]);
  });

  it('caps at 100 items, dropping the oldest', async () => {
    const queue = new PersistentQueue(memoryStorage());
    for (let i = 0; i < 105; i++) {
      await queue.append({ path: `/${i}`, body: '' });
    }
    const items = await queue.load();
    expect(items).toHaveLength(100);
    expect(items[0]?.path).toBe('/5');
    expect(items[99]?.path).toBe('/104');
  });

  it('returns [] for corrupt stored JSON', async () => {
    const storage = memoryStorage();
    await storage.setItem('rh_queue', 'not json');
    expect(await new PersistentQueue(storage).load()).toEqual([]);
  });

  it('clear() empties the queue', async () => {
    const queue = new PersistentQueue(memoryStorage());
    await queue.append({ path: '/a', body: '1' });
    await queue.clear();
    expect(await queue.load()).toEqual([]);
  });
});
