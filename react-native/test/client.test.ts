import { describe, expect, it } from 'vitest';
import { memoryStorage } from '../src/storage';
import { makeClient, mockFetch } from './helpers';

describe('HogClient', () => {
  it('identify posts the full payload with no Authorization header', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);

    await client.identify('user_42');

    const request = transport.requests[0];
    expect(request?.url).toBe('https://example.test/api/sdk/v1/identify');
    expect(request?.headers.Authorization).toBeUndefined();
    expect(request?.headers['Content-Type']).toBe('application/json');
    expect(request?.body).toMatchObject({
      appUserId: 'user_42',
      bundleId: 'com.example.app',
      platform: 'ios',
      osVersion: '17.0.0',
      deviceModel: 'iPhone15,2',
      locale: 'en-US',
    });
  });

  it('setAttributes sends a flat attributes map on the identify payload', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);

    await client.setAttributes({ plan: 'pro', cohort: '2026-07' });

    expect(transport.requests[0]?.body.attributes).toEqual({
      plan: 'pro',
      cohort: '2026-07',
    });
  });

  it('attributePurchase before identify uses a persisted anonymous id', async () => {
    const storage = memoryStorage();
    const transport = mockFetch();
    const { client } = makeClient(transport, {}, storage);

    await client.attributePurchase({
      originalTransactionId: 'txn_1',
      productId: 'pro.monthly',
    });

    const first = transport.requests[0];
    expect(first?.url).toBe('https://example.test/api/sdk/v1/attribute');
    const anonId = first?.body.appUserId as string;
    expect(anonId).toMatch(/^\$anon_/);

    // "second launch" with the same storage keeps the same anon id
    const { client: second } = makeClient(transport, {}, storage);
    await second.setAttributes({ a: 'b' });
    expect(transport.requests[1]?.body.appUserId).toBe(anonId);
  });

  it('identify re-attributes transactions reported anonymously', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);

    await client.attributePurchase({
      originalTransactionId: 'txn_1',
      productId: 'pro.monthly',
    });
    await client.identify('user_42');

    const attributes = transport.requests
      .filter((r) => r.url.endsWith('/attribute'))
      .map((r) => r.body.appUserId);
    expect(attributes).toHaveLength(2);
    expect(attributes[0]).toMatch(/^\$anon_/);
    expect(attributes[1]).toBe('user_42');
    expect(
      transport.requests
        .filter((r) => r.url.endsWith('/attribute'))
        .map((r) => r.body.originalTransactionId)
    ).toEqual(['txn_1', 'txn_1']);
  });

  it('attributePurchase forwards the StoreKit 2 JWS when provided', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);
    const jws = 'eyJhbGciOiJFUzI1NiJ9.eyJidW5kbGVJZCI6ImNvbS5leGFtcGxlLmFwcCJ9.c2ln';

    await client.attributePurchase({
      originalTransactionId: 'txn_1',
      productId: 'pro.monthly',
      jws,
    });

    expect(transport.requests[0]?.body).toMatchObject({
      originalTransactionId: 'txn_1',
      productId: 'pro.monthly',
      jws,
    });
  });

  it('attributePurchase omits jws from the body when absent', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);

    await client.attributePurchase({ originalTransactionId: 'txn_1' });

    expect(transport.requests[0]?.body).not.toHaveProperty('jws');
  });

  it('skips duplicate attribution for the same user', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);

    await client.attributePurchase({ originalTransactionId: 'txn_1' });
    await client.attributePurchase({ originalTransactionId: 'txn_1' });

    expect(transport.requests).toHaveLength(1);
  });

  it('queues after exhausting retries on 429, then flushes when healthy', async () => {
    const storage = memoryStorage();
    const transport = mockFetch([429, 429, 429]);
    const { client } = makeClient(transport, {}, storage);

    await client.setAttributes({ plan: 'pro' });
    expect(JSON.parse((await storage.getItem('rh_queue')) ?? '[]')).toHaveLength(1);

    await client.flush();
    expect(await storage.getItem('rh_queue')).toBeNull();
    expect(transport.requests).toHaveLength(4);
    expect(transport.requests[3]?.body.attributes).toEqual({ plan: 'pro' });
  });

  it('retries network errors then queues', async () => {
    const storage = memoryStorage();
    const transport = mockFetch(['network-error', 'network-error', 'network-error']);
    const { client } = makeClient(transport, {}, storage);

    await client.setAttributes({ a: 'b' });

    expect(transport.requests).toHaveLength(3);
    expect(JSON.parse((await storage.getItem('rh_queue')) ?? '[]')).toHaveLength(1);
  });

  it('drops on 401 without queueing or retrying', async () => {
    const storage = memoryStorage();
    const transport = mockFetch([401]);
    const { client } = makeClient(transport, {}, storage);

    await client.setAttributes({ a: 'b' });

    expect(transport.requests).toHaveLength(1);
    expect(await storage.getItem('rh_queue')).toBeNull();
  });

  it('reset issues a fresh anonymous id and clears identity', async () => {
    const storage = memoryStorage();
    const transport = mockFetch();
    const { client } = makeClient(transport, {}, storage);

    await client.identify('user_42');
    await client.reset();
    await client.setAttributes({ a: 'b' });

    const last = transport.requests.at(-1);
    expect(last?.body.appUserId).toMatch(/^\$anon_/);
    expect(await storage.getItem('rh_user_id')).toBeNull();
  });

  it('never rejects — even when storage explodes', async () => {
    const transport = mockFetch();
    const broken = {
      getItem: () => Promise.reject(new Error('boom')),
      setItem: () => Promise.reject(new Error('boom')),
      removeItem: () => Promise.reject(new Error('boom')),
    };
    const { client } = makeClient(transport, {}, broken);

    await expect(client.identify('user_42')).resolves.toBeUndefined();
    await expect(
      client.attributePurchase({ originalTransactionId: 't' })
    ).resolves.toBeUndefined();
    await expect(client.reset()).resolves.toBeUndefined();
  });
});
