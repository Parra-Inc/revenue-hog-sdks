import { describe, expect, it } from 'vitest';
import { memoryStorage } from '../src/storage';
import { HogClient } from '../src/client';
import { makeClient, mockFetch, type MockFetch } from './helpers';

const EXPERIMENT_JSON = JSON.stringify({
  entitlement: 'pro',
  skus: [
    { productId: 'pro_annual', kind: 'subscription' },
    { productId: 'pro_monthly', kind: 'subscription' },
    { productId: 'credits_500', kind: 'iap' },
  ],
  experimentId: 'exp_1',
  variantKey: 'b',
  ttlSeconds: 900,
});

function paywallRequests(transport: MockFetch) {
  return transport.requests.filter((r) => r.url.endsWith('/api/sdk/v1/paywall'));
}

describe('paywall', () => {
  it('sends the installId and decodes the ordered menu', async () => {
    const transport = mockFetch([{ status: 200, json: EXPERIMENT_JSON }]);
    const { client } = makeClient(transport);

    const paywall = await client.paywall('pro', ['fb_monthly']);

    expect(paywall.productIds).toEqual(['pro_annual', 'pro_monthly', 'credits_500']);
    expect(paywall.skus.map((s) => s.kind)).toEqual(['subscription', 'subscription', 'iap']);
    expect(paywall.experimentId).toBe('exp_1');
    expect(paywall.variantKey).toBe('b');
    expect(paywall.isFallback).toBe(false);

    const request = paywallRequests(transport)[0];
    expect(request.body.entitlement).toBe('pro');
    expect(request.body.bundleId).toBe('com.example.app');
    expect(String(request.body.installId).length).toBeGreaterThan(0);
    expect(String(request.body.appUserId).startsWith('$anon_')).toBe(true);
  });

  it('persists the installId across clients and reset', async () => {
    const storage = memoryStorage();
    const transport = mockFetch([
      { status: 200, json: EXPERIMENT_JSON },
      { status: 200, json: EXPERIMENT_JSON },
    ]);
    const { client } = makeClient(transport, {}, storage);
    await client.paywall('pro', []);
    await client.reset();

    const second = makeClient(transport, {}, storage).client;
    await second.paywall('pro', []);

    const ids = paywallRequests(transport).map((r) => r.body.installId);
    expect(ids).toHaveLength(2);
    expect(ids[0]).toBe(ids[1]);
  });

  it('serves a fresh cache without touching the network', async () => {
    const transport = mockFetch([{ status: 200, json: EXPERIMENT_JSON }]);
    const { client } = makeClient(transport);

    const first = await client.paywall('pro', []);
    const second = await client.paywall('pro', []);

    expect(second).toEqual(first);
    expect(paywallRequests(transport)).toHaveLength(1);
  });

  it('an empty answer serves the compiled-in fallback', async () => {
    const transport = mockFetch([
      { status: 200, json: '{"entitlement":"pro","skus":[],"ttlSeconds":3600}' },
    ]);
    const { client } = makeClient(transport);

    const paywall = await client.paywall('pro', ['fb_monthly', 'fb_annual']);

    expect(paywall.isFallback).toBe(true);
    expect(paywall.productIds).toEqual(['fb_monthly', 'fb_annual']);
    expect(paywall.skus.map((s) => s.kind)).toEqual(['unknown', 'unknown']);
    expect(paywall.experimentId).toBeUndefined();
  });

  it('a network failure serves stale cache, however old', async () => {
    const storage = memoryStorage();
    const transport = mockFetch(['network-error']);
    const { client } = makeClient(transport, {}, storage);
    // Seed an entry far past its TTL under the client's own anonymous id.
    const probe = mockFetch([{ status: 200, json: EXPERIMENT_JSON }]);
    await makeClient(probe, {}, storage).client.paywall('probe', []);
    const anonId = String(paywallRequests(probe)[0].body.appUserId);
    await storage.setItem(
      'rh_paywall_cache',
      JSON.stringify({
        pro: {
          entitlement: 'pro',
          skus: [{ productId: 'cached_annual', kind: 'subscription' }],
          experimentId: 'exp_1',
          variantKey: 'b',
          ttlSeconds: 60,
          fetchedAt: Date.now() - 7_200_000,
          appUserId: anonId,
        },
      })
    );

    const paywall = await client.paywall('pro', ['fb']);

    expect(paywall.productIds).toEqual(['cached_annual']);
    expect(paywall.variantKey).toBe('b');
    expect(paywall.isFallback).toBe(false);
  });

  it('a network failure with no cache serves the fallback', async () => {
    const transport = mockFetch(['network-error']);
    const { client } = makeClient(transport);

    const paywall = await client.paywall('pro', ['fb_monthly']);

    expect(paywall.isFallback).toBe(true);
    expect(paywall.productIds).toEqual(['fb_monthly']);
  });

  it('an identity change invalidates the cache', async () => {
    const transport = mockFetch([
      { status: 200, json: EXPERIMENT_JSON },
      200,
      { status: 200, json: EXPERIMENT_JSON },
    ]);
    const { client } = makeClient(transport);

    await client.paywall('pro', []);
    await client.identify('user_42');
    await client.paywall('pro', []);

    const requests = paywallRequests(transport);
    expect(requests).toHaveLength(2);
    expect(requests[1].body.appUserId).toBe('user_42');
  });

  it('forceVariant bypasses and never poisons the cache', async () => {
    const forced = JSON.stringify({
      entitlement: 'pro',
      skus: [{ productId: 'forced_sku', kind: 'subscription' }],
      experimentId: 'exp_1',
      variantKey: 'c',
      forced: true,
      ttlSeconds: 900,
    });
    const transport = mockFetch([
      { status: 200, json: forced },
      { status: 200, json: EXPERIMENT_JSON },
    ]);
    const { client } = makeClient(transport);

    const preview = await client.paywall('pro', [], { forceVariant: 'c' });
    const real = await client.paywall('pro', []);

    expect(preview.productIds).toEqual(['forced_sku']);
    expect(real.productIds).toEqual(['pro_annual', 'pro_monthly', 'credits_500']);
    const requests = paywallRequests(transport);
    expect(requests).toHaveLength(2);
    expect(requests[0].body.forceVariant).toBe('c');
    expect(requests[1].body.forceVariant).toBeUndefined();
  });

  it('a hanging network falls back within the deadline', async () => {
    const transport = mockFetch(['hang']);
    const { client } = makeClient(transport);
    const fast = new HogClient(
      {
        baseUrl: 'https://example.test',
        bundleId: 'com.example.app',
        logLevel: 'silent',
        storage: memoryStorage(),
        fetch: transport.fetch,
      },
      { backoffMs: () => 0, paywallTimeoutMs: 50 }
    );
    void client;

    const started = Date.now();
    const paywall = await fast.paywall('pro', ['fb']);

    expect(paywall.isFallback).toBe(true);
    expect(paywall.productIds).toEqual(['fb']);
    expect(Date.now() - started).toBeLessThan(1500);
  });

  it('sends the configured store environment', async () => {
    const transport = mockFetch([{ status: 200, json: EXPERIMENT_JSON }]);
    const { client } = makeClient(transport, { storeEnvironment: 'Sandbox' });

    await client.paywall('pro', []);

    expect(paywallRequests(transport)[0].body.environment).toBe('Sandbox');
  });

  it('paywallShown posts the impression only under an experiment', async () => {
    const transport = mockFetch([{ status: 200, json: EXPERIMENT_JSON }, 200]);
    const { client } = makeClient(transport);

    const paywall = await client.paywall('pro', []);
    await client.paywallShown(paywall, ['pro_annual', 'pro_monthly']);

    const impressions = transport.requests.filter((r) =>
      r.url.endsWith('/api/sdk/v1/paywall/impression')
    );
    expect(impressions).toHaveLength(1);
    expect(impressions[0].body.experimentId).toBe('exp_1');
    expect(impressions[0].body.renderedSkus).toEqual(['pro_annual', 'pro_monthly']);
    expect(impressions[0].body.installId).toBe(paywallRequests(transport)[0].body.installId);

    await client.paywallShown(
      {
        entitlement: 'pro',
        skus: [],
        productIds: [],
        isFallback: true,
      },
      ['fb']
    );
    expect(
      transport.requests.filter((r) => r.url.endsWith('/api/sdk/v1/paywall/impression'))
    ).toHaveLength(1);
  });

  it('unknown kinds decode as unknown', async () => {
    const future = JSON.stringify({
      entitlement: 'pro',
      skus: [{ productId: 'x', kind: 'bundle' }],
      ttlSeconds: 900,
    });
    const transport = mockFetch([{ status: 200, json: future }]);
    const { client } = makeClient(transport);

    const paywall = await client.paywall('pro', []);

    expect(paywall.skus.map((s) => s.kind)).toEqual(['unknown']);
    expect(paywall.isFallback).toBe(false);
  });
});
