import { describe, expect, it } from 'vitest';
import {
  fnv1a,
  inSample,
  isCapped,
  newlyCancelled,
  orderOptions,
  parseSurvey,
  shownOrder,
  utcDay,
} from '../src/churnSurvey';
import { renewalsFromPurchases } from '../src/autoAttribution';
import { makeClient, mockFetch } from './helpers';
import { memoryStorage } from '../src/storage';

const SURVEY = {
  survey: {
    version: 3,
    title: 'Why are you leaving?',
    options: [
      { key: 'too_expensive', title: "It's too expensive" },
      { key: 'not_using', title: "I don't use it enough" },
      { key: 'missing_feature', title: 'Missing a feature' },
      { key: 'found_another_app', title: 'Found another app' },
    ],
    other: { enabled: true, placeholder: 'Tell us more', key: 'other' },
    randomize: true,
    trigger: { onAutoRenewOff: true, maxPerUserDays: 90 },
    sampleRate: 1,
  },
  show: true,
  reason: null,
};
const SURVEY_JSON = JSON.stringify(SURVEY);
const DAY = 86_400_000;

function seeded(seed: number): () => number {
  let s = seed;
  return () => {
    s = (s * 1_103_515_245 + 12_345) % 2_147_483_648;
    return s / 2_147_483_648;
  };
}

describe('churn survey rules', () => {
  const opts = ['a1', 'b1', 'c1', 'd1'].map((key) => ({ key, title: key }));

  it('shuffles, keeps Other out of the list and last in shownOrder', () => {
    const rand = seeded(3);
    const seen = new Set<string>();
    for (let i = 0; i < 30; i++) {
      const ordered = orderOptions([...opts, { key: 'other', title: 'Other' }], true, rand);
      expect(ordered.map((o) => o.key).sort()).toEqual(['a1', 'b1', 'c1', 'd1']);
      seen.add(ordered.map((o) => o.key).join());
      expect(shownOrder(ordered, true).at(-1)).toBe('other');
    }
    expect(seen.size).toBeGreaterThan(1);
    expect(orderOptions(opts, false).map((o) => o.key)).toEqual(['a1', 'b1', 'c1', 'd1']);
  });

  it('caps at 90 days and 0 means no cap', () => {
    const now = 1_800_000_000_000;
    expect(isCapped(null, now, 90)).toBe(false);
    expect(isCapped(now - 89 * DAY, now, 90)).toBe(true);
    expect(isCapped(now - 91 * DAY, now, 90)).toBe(false);
    expect(isCapped(now, now, 0)).toBe(false);
  });

  it('samples with the server hash', () => {
    expect(fnv1a('a')).toBe(0xe40c292c);
    expect(inSample(1, 'x')).toBe(true);
    expect(inSample(0, 'x')).toBe(false);
    const hits = Array.from({ length: 2000 }, (_, i) => inSample(0.25, `user_${i}`)).filter(Boolean).length;
    expect(hits).toBeGreaterThan(350);
    expect(hits).toBeLessThan(650);
  });

  it('asks once per cancellation', () => {
    expect(newlyCancelled([{ originalId: 't1', willAutoRenew: false }], []).fresh).toEqual(['t1']);
    expect(newlyCancelled([{ originalId: 't1', willAutoRenew: false }], ['t1']).fresh).toEqual([]);
    expect(newlyCancelled([{ originalId: 't1', willAutoRenew: true }], ['t1']).handled).toEqual([]);
  });

  it('parses leniently and returns null for nothing to show', () => {
    expect(parseSurvey(null)).toBeNull();
    expect(parseSurvey({ options: [], other: { enabled: false } })).toBeNull();
    const parsed = parseSurvey(SURVEY.survey);
    expect(parsed?.survey.shownOrder).toHaveLength(5);
    expect(parsed?.maxPerUserDays).toBe(90);
  });

  it('reads Android auto-renew state from react-native-iap purchases', () => {
    expect(
      renewalsFromPurchases([
        { purchaseToken: 'tok', productId: 'pro', autoRenewingAndroid: false },
        { transactionId: 'ios', productId: 'x' },
      ])
    ).toEqual([{ originalId: 'tok', productId: 'pro', willAutoRenew: false }]);
  });

  it('formats the UTC day', () => {
    expect(utcDay(Date.UTC(2026, 10, 10, 23, 59))).toBe('2026-11-10');
  });
});

describe('churn survey client', () => {
  it('fetches with GET and the right query, then caps locally', async () => {
    const transport = mockFetch([
      { status: 200, json: SURVEY_JSON },
      { status: 200, json: SURVEY_JSON },
    ]);
    const { client } = makeClient(transport);
    const survey = await client.churnSurvey();
    expect(survey?.version).toBe(3);
    const req = transport.requests[0];
    expect(req.method).toBe('GET');
    expect(req.url).toContain('/api/sdk/v1/churn-survey?bundleId=com.example.app');
    expect(req.url).toContain('locale=en-US');
    await client.churnSurveyShown();
    expect(await client.churnSurvey()).toBeNull();
  });

  it('respects show:false and the auto-renew switch', async () => {
    const off = JSON.stringify({ survey: null, show: false, reason: 'disabled' });
    const noAuto = JSON.stringify({
      ...SURVEY,
      survey: { ...SURVEY.survey, trigger: { onAutoRenewOff: false, maxPerUserDays: 90 } },
    });
    const transport = mockFetch([
      { status: 200, json: off },
      { status: 200, json: noAuto },
      { status: 200, json: noAuto },
    ]);
    const { client } = makeClient(transport);
    expect(await client.churnSurvey()).toBeNull();
    expect(await client.churnSurvey(true)).toBeNull();
    expect(await client.churnSurvey(false)).not.toBeNull();
  });

  it('posts the answer with the shown order', async () => {
    const transport = mockFetch([{ status: 200, json: SURVEY_JSON }]);
    const { client } = makeClient(transport);
    const survey = (await client.churnSurvey())!;
    await client.submitChurnSurvey(survey, { type: 'option', key: 'not_using' }, 'pro.monthly');
    await client.submitChurnSurvey(survey, { type: 'skipped' });
    const posts = transport.requests.filter((r) => r.url.endsWith('/churn-survey/response'));
    expect(posts[0].body.optionKey).toBe('not_using');
    expect(posts[0].body.shownOrder).toEqual(survey.shownOrder);
    expect(posts[0].body.surveyVersion).toBe(3);
    expect(posts[0].body.productId).toBe('pro.monthly');
    expect(posts[1].body.skipped).toBe(true);
  });
});

describe('daily open ping', () => {
  it('sends once per UTC day under the anonymous id', async () => {
    const transport = mockFetch();
    let now = Date.UTC(2026, 10, 10, 9);
    const { client } = makeClient(transport, {}, memoryStorage(), () => now);
    await client.sendDailyOpen();
    await client.sendDailyOpen();
    let opens = transport.requests.filter((r) => r.url.endsWith('/api/sdk/v1/open'));
    expect(opens).toHaveLength(1);
    expect(String(opens[0].body.appUserId).startsWith('$anon_')).toBe(true);
    now += DAY;
    await client.sendDailyOpen();
    opens = transport.requests.filter((r) => r.url.endsWith('/api/sdk/v1/open'));
    expect(opens).toHaveLength(2);
  });

  it('first identify carries the anonymous id for the merge', async () => {
    const transport = mockFetch();
    const { client } = makeClient(transport);
    await client.sendDailyOpen();
    const anon = transport.requests[0].body.appUserId;
    await client.identify('user_1');
    await client.identify('user_2');
    const ids = transport.requests.filter((r) => r.url.endsWith('/identify'));
    expect(ids[0].body.anonymousAppUserId).toBe(anon);
    expect(ids[1].body.anonymousAppUserId).toBeUndefined();
  });
});
