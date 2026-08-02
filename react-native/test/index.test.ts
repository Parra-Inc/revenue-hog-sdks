import { describe, expect, it } from 'vitest';
import RevenueHog from '../src/index';
import { memoryStorage } from '../src/storage';
import type { FetchLike } from '../src/types';

describe('RevenueHog singleton', () => {
  it('methods before configure are safe no-ops', async () => {
    await expect(RevenueHog.identify('u')).resolves.toBeUndefined();
    await expect(RevenueHog.setAttributes({ a: 'b' })).resolves.toBeUndefined();
    await expect(
      RevenueHog.attributePurchase({ originalTransactionId: 't' })
    ).resolves.toBeUndefined();
    await expect(RevenueHog.reset()).resolves.toBeUndefined();
  });

  it('configure wires the client; identify hits the API', async () => {
    const urls: string[] = [];
    const fetchFn: FetchLike = async (url) => {
      urls.push(url);
      return { status: 200 };
    };
    RevenueHog.configure({
      baseUrl: 'https://example.test',
      bundleId: 'com.example.app',
      storage: memoryStorage(),
      logLevel: 'silent',
      fetch: fetchFn,
      autoAttribution: false,
    });

    await RevenueHog.identify('user_1');
    expect(urls).toContain('https://example.test/api/sdk/v1/identify');
  });

  it('configure never throws, even with auto-attribution on and no iap module', () => {
    expect(() =>
      RevenueHog.configure({
        bundleId: 'com.example.app',
        storage: memoryStorage(),
        logLevel: 'silent',
        fetch: async () => ({ status: 200 }),
        autoAttribution: true, // react-native-iap absent in tests → silent no-op
      })
    ).not.toThrow();
  });
});
