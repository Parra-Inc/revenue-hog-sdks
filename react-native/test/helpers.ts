import { HogClient } from '../src/client';
import { memoryStorage } from '../src/storage';
import type { FetchLike, RevenueHogConfig, StorageAdapter } from '../src/types';

export interface Recorded {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

export interface MockFetch {
  fetch: FetchLike;
  requests: Recorded[];
}

export type ScriptedResponse =
  | number
  | 'network-error'
  /** Never answers: the slow-network case the paywall timeout races. */
  | 'hang'
  | { status: number; json: string };

/** Responses are consumed in order; once the script runs dry, everything is 200. */
export function mockFetch(script: ScriptedResponse[] = []): MockFetch {
  const requests: Recorded[] = [];
  const fetchFn: FetchLike = async (url, init) => {
    requests.push({
      url,
      headers: init.headers,
      body: JSON.parse(init.body) as Record<string, unknown>,
    });
    const next = script.length > 0 ? (script.shift() as ScriptedResponse) : 200;
    if (next === 'network-error') throw new TypeError('Network request failed');
    if (next === 'hang') return new Promise(() => {});
    if (typeof next === 'object') {
      return { status: next.status, text: async () => next.json };
    }
    return { status: next };
  };
  return { fetch: fetchFn, requests };
}

export function makeClient(
  transport: MockFetch,
  overrides: Partial<RevenueHogConfig> = {},
  storage: StorageAdapter = memoryStorage()
): { client: HogClient; storage: StorageAdapter } {
  const client = new HogClient(
    {
      baseUrl: 'https://example.test',
      bundleId: 'com.example.app',
      logLevel: 'silent',
      storage,
      fetch: transport.fetch,
      ...overrides,
    },
    {
      device: {
        bundleId: overrides.bundleId ?? 'com.example.app',
        platform: 'ios',
        osVersion: '17.0.0',
        deviceModel: 'iPhone15,2',
        locale: 'en-US',
      },
      backoffMs: () => 0,
    }
  );
  return { client, storage };
}
