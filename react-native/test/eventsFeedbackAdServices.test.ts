import { describe, expect, it } from 'vitest';
import { HogClient, validEventName } from '../src/client';
import { memoryStorage } from '../src/storage';
import { PersistentQueue } from '../src/queue';
import { makeClient, mockFetch } from './helpers';

const at = (path: string) => (r: { url: string }) => r.url.endsWith(path);

describe('track', () => {
  it('buffers until flush, then sends one batch', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);

    await client.track('onboarding_step', { step: 'welcome', index: 0 });
    await client.track('paywall_viewed');
    expect(transport.requests.filter(at('/events'))).toHaveLength(0);

    await client.flush();
    const sent = transport.requests.filter(at('/api/sdk/v1/events'));
    expect(sent).toHaveLength(1);
    expect(sent[0]?.body).toMatchObject({ bundleId: 'com.example.app', platform: 'ios' });
    const events = sent[0]?.body.events as Record<string, unknown>[];
    expect(events.map((e) => e.name)).toEqual(['onboarding_step', 'paywall_viewed']);
    expect(events[0]?.properties).toEqual({ step: 'welcome', index: 0 });
    expect(String(events[0]?.appUserId)).toMatch(/^\$anon_/);
    expect(typeof events[0]?.at).toBe('number');
    expect(events[1]).not.toHaveProperty('properties');
  });

  it('drops invalid names', async () => {
    for (const bad of ['', 'Signup', '1st', 'rh_x', 'a-b', 'a'.repeat(49)]) {
      expect(validEventName(bad)).toBeNull();
    }
    expect(validEventName('signup_done')).toBe('signup_done');
    const transport = mockFetch();
    const { client } = makeClient(transport);
    await client.track('Bad Name');
    await client.flush();
    expect(transport.requests).toHaveLength(0);
  });

  it('sends automatically at 20 and caps batches at 50', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);
    for (let i = 0; i < 20; i++) await client.track('tap');
    expect(transport.requests.filter(at('/events'))).toHaveLength(1);

    const storage = memoryStorage();
    const events = Array.from({ length: 120 }, (_, i) => ({ name: 'tap', at: i, appUserId: 'u' }));
    await storage.setItem('rh_event_buffer', JSON.stringify(events));
    const t2 = mockFetch();
    const { client: c2 } = makeClient(t2, {}, storage);
    await c2.flush();
    expect(t2.requests.filter(at('/events')).map((r) => (r.body.events as unknown[]).length)).toEqual([
      50, 50, 20,
    ]);
  });

  it('queues an offline batch and replays it', async () => {
    const storage = memoryStorage();
    const transport = mockFetch(['network-error', 'network-error', 'network-error', 'network-error']);
    const { client } = makeClient(transport, {}, storage);
    await client.track('tap');
    await client.flush();
    expect((await new PersistentQueue(storage).load()).map((p) => p.path)).toEqual(['/api/sdk/v1/events']);
    await client.flush();
    expect(await new PersistentQueue(storage).load()).toEqual([]);
  });

  it('flushes on a timer', async () => {
    const transport = mockFetch();
    const client = new HogClient(
      { baseUrl: 'https://example.test', bundleId: 'com.example.app', logLevel: 'silent', fetch: transport.fetch },
      { device: { platform: 'ios', bundleId: 'com.example.app' }, backoffMs: () => 0, eventFlushDelayMs: 10 }
    );
    await client.track('tap');
    await new Promise((r) => setTimeout(r, 80));
    expect(transport.requests.filter(at('/events'))).toHaveLength(1);
  });
});

describe('sendFeedback', () => {
  it('sends the full payload with device context and returns the id', async () => {
    const transport = mockFetch([200, { status: 200, json: '{"ok":true,"id":"fb_1"}' }]);
    const { client } = makeClient(transport);
    await client.identify('user_42');

    const result = await client.sendFeedback({
      kind: 'bug',
      message: '  It crashed  ',
      rating: 2,
      data: { screen: 'settings' },
      metadata: { build: 42 },
    });

    expect(result).toEqual({ status: 'sent', id: 'fb_1' });
    const req = transport.requests.find(at('/api/sdk/v1/feedback'));
    expect(req?.body).toEqual({
      bundleId: 'com.example.app',
      platform: 'ios',
      appUserId: 'user_42',
      kind: 'bug',
      message: 'It crashed',
      rating: 2,
      data: { screen: 'settings' },
      metadata: {
        osVersion: '17.0.0',
        deviceModel: 'iPhone15,2',
        locale: 'en-US',
        appVersion: '2.1.0',
        build: 42,
      },
    });
  });

  it('rejects invalid input locally', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);
    expect(await client.sendFeedback({ kind: 'bug', message: '  ' })).toEqual({
      status: 'rejected',
      reason: 'message is required',
    });
    expect((await client.sendFeedback({ kind: 'bug', message: 'x', rating: 6 })).status).toBe('rejected');
    expect((await client.sendFeedback({ kind: 'nope' as never, message: 'x' })).status).toBe('rejected');
    expect((await client.sendFeedback({ kind: 'bug', message: 'a'.repeat(5001) })).status).toBe('rejected');
    expect(transport.requests).toHaveLength(0);
  });

  it('queues offline feedback and delivers it on flush', async () => {
    const storage = memoryStorage();
    const transport = mockFetch(['network-error', 503, 'network-error']);
    const { client } = makeClient(transport, {}, storage);
    expect(await client.sendFeedback({ kind: 'idea', message: 'Dark mode' })).toEqual({ status: 'queued' });
    expect((await new PersistentQueue(storage).load()).map((p) => p.path)).toEqual(['/api/sdk/v1/feedback']);
    await client.flush();
    expect(await new PersistentQueue(storage).load()).toEqual([]);
    expect(transport.requests.filter(at('/feedback'))).toHaveLength(4);
  });

  it('does not queue a server rejection', async () => {
    const storage = memoryStorage();
    const { client } = makeClient(mockFetch([400]), {}, storage);
    expect(await client.sendFeedback({ kind: 'praise', message: 'Love it' })).toEqual({
      status: 'rejected',
      reason: 'HTTP 400',
    });
    expect(await new PersistentQueue(storage).load()).toEqual([]);
  });
});

describe('sendAdServicesToken', () => {
  it('sends once per install with installId and environment', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport, { storeEnvironment: 'Sandbox' });
    await client.sendAdServicesToken('tok_abc', { storefront: 'USA' });
    await client.sendAdServicesToken('tok_abc');
    const sent = transport.requests.filter(at('/api/sdk/v1/adservices'));
    expect(sent).toHaveLength(1);
    expect(sent[0]?.body).toMatchObject({
      bundleId: 'com.example.app',
      platform: 'ios',
      token: 'tok_abc',
      environment: 'sandbox',
      appVersion: '2.1.0',
      storefront: 'USA',
    });
    expect(typeof sent[0]?.body.installId).toBe('string');
  });

  it('ignores empty tokens and Android', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);
    await client.sendAdServicesToken('  ');
    const android = new HogClient(
      { baseUrl: 'https://example.test', logLevel: 'silent', fetch: transport.fetch },
      { device: { platform: 'android', bundleId: 'b' }, backoffMs: () => 0 }
    );
    await android.sendAdServicesToken('tok');
    expect(transport.requests).toHaveLength(0);
  });

  it('queues the token offline and sets the flag only after delivery', async () => {
    const storage = memoryStorage();
    const transport = mockFetch(['network-error', 'network-error', 'network-error']);
    const { client } = makeClient(transport, {}, storage);
    await client.sendAdServicesToken('tok');
    expect((await new PersistentQueue(storage).load()).map((p) => p.path)).toEqual(['/api/sdk/v1/adservices']);
    expect(await storage.getItem('rh_adservices_sent')).toBeNull();

    await client.sendAdServicesToken('tok'); // still queued: no duplicate
    expect(await new PersistentQueue(storage).load()).toHaveLength(1);

    await client.flush();
    expect(await new PersistentQueue(storage).load()).toEqual([]);
    expect(await storage.getItem('rh_adservices_sent')).toBe('1');
  });

  it('sends again when a queued token was dropped', async () => {
    const storage = memoryStorage();
    const transport = mockFetch(['network-error', 'network-error', 'network-error']);
    const { client } = makeClient(transport, {}, storage);
    await client.sendAdServicesToken('tok');
    await new PersistentQueue(storage).clear();
    await client.sendAdServicesToken('tok');
    expect(await storage.getItem('rh_adservices_sent')).toBe('1');
    expect(transport.requests.filter(at('/adservices'))).toHaveLength(4);
  });

  it('a permanent rejection sets the flag and is not queued', async () => {
    const storage = memoryStorage();
    const { client } = makeClient(mockFetch([400]), {}, storage);
    await client.sendAdServicesToken('tok');
    expect(await storage.getItem('rh_adservices_sent')).toBe('1');
    expect(await new PersistentQueue(storage).load()).toEqual([]);
  });
});

describe('reset keeps pending work', () => {
  it('delivers queued feedback, AdServices and buffered events under the original user', async () => {
    const storage = memoryStorage();
    const net = 'network-error' as const;
    const transport = mockFetch([200, net, net, net, net, net, net]);
    const { client } = makeClient(transport, {}, storage);
    await client.identify('user_old');
    expect((await client.sendFeedback({ kind: 'bug', message: 'broken' })).status).toBe('queued');
    await client.sendAdServicesToken('tok');
    await client.track('tap');

    await client.reset();
    expect((await new PersistentQueue(storage).load()).map((p) => p.path)).toEqual([
      '/api/sdk/v1/feedback',
      '/api/sdk/v1/adservices',
    ]);

    await client.flush();
    expect(transport.requests.filter(at('/feedback')).pop()?.body.appUserId).toBe('user_old');
    const events = transport.requests.find(at('/events'))?.body.events as Record<string, unknown>[];
    expect(events[0]?.appUserId).toBe('user_old');
    expect(await new PersistentQueue(storage).load()).toEqual([]);
    expect(await storage.getItem('rh_adservices_sent')).toBe('1');
    expect(await storage.getItem('rh_anon_id')).toMatch(/^\$anon_/);
  });
});
