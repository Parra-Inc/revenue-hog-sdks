/**
 * Pure churn survey rules: ordering, the frequency cap, sampling and the
 * auto-renew-off bookkeeping. No networking or UI, so all of it is unit tested.
 */
import type { ChurnSurvey, ChurnSurveyOption } from './types';

export const OTHER_KEY = 'other';
export const DEFAULT_MAX_PER_USER_DAYS = 90;
const DAY_MS = 86_400_000;

/** Fisher-Yates over a copy, with an injectable random source for tests. */
export function shuffle<T>(items: T[], rand: () => number = Math.random): T[] {
  const a = [...items];
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rand() * (i + 1));
    [a[i], a[j]] = [a[j] as T, a[i] as T];
  }
  return a;
}

/** Render order: shuffled when `randomize` is on; "Other" never in the list. */
export function orderOptions(
  options: ChurnSurveyOption[],
  randomize: boolean,
  rand: () => number = Math.random
): ChurnSurveyOption[] {
  const live = options.filter((o) => o.key !== OTHER_KEY);
  return randomize ? shuffle(live, rand) : live;
}

/** Keys in shown order, "other" last when enabled. */
export function shownOrder(options: ChurnSurveyOption[], otherEnabled: boolean): string[] {
  return [...options.map((o) => o.key), ...(otherEnabled ? [OTHER_KEY] : [])];
}

/** True while the last appearance is inside the cap window. 0 days = no cap. */
export function isCapped(lastShownAt: number | null, now: number, maxPerUserDays: number): boolean {
  if (lastShownAt == null || maxPerUserDays <= 0) return false;
  return now - lastShownAt < maxPerUserDays * DAY_MS;
}

/** 32-bit FNV-1a, identical to the server's. */
export function fnv1a(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h >>> 0;
}

/**
 * Deterministic sampling by seed. Only used when the server answer carries
 * no `show` decision (older servers); otherwise the server already sampled.
 */
export function inSample(sampleRate: number, seed: string): boolean {
  if (sampleRate >= 1) return true;
  if (sampleRate <= 0) return false;
  return fnv1a(seed) / 0x1_0000_0000 < sampleRate;
}

/**
 * Subscriptions whose auto-renew newly turned off, plus the next handled
 * set: ids whose auto-renew came back on drop out so a later cancel counts.
 */
export function newlyCancelled(
  renewals: { originalId: string; willAutoRenew: boolean }[],
  handled: string[]
): { fresh: string[]; handled: string[] } {
  const next = new Set(handled);
  const fresh: string[] = [];
  for (const r of renewals) {
    if (r.willAutoRenew) next.delete(r.originalId);
    else if (!next.has(r.originalId)) fresh.push(r.originalId);
  }
  return { fresh, handled: [...next].sort() };
}

export interface ParsedSurvey {
  survey: ChurnSurvey;
  autoRenewTrigger: boolean;
  maxPerUserDays: number;
  sampleRate: number;
}

/** Lenient decode of the GET /api/sdk/v1/churn-survey `survey` object. */
export function parseSurvey(raw: unknown, rand: () => number = Math.random): ParsedSurvey | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const options: ChurnSurveyOption[] = [];
  if (Array.isArray(r.options)) {
    for (const o of r.options) {
      if (!o || typeof o !== 'object') continue;
      const { key, title } = o as Record<string, unknown>;
      if (typeof key === 'string' && key && typeof title === 'string' && title) {
        options.push({ key, title });
      }
    }
  }
  const other = (r.other && typeof r.other === 'object' ? r.other : {}) as Record<string, unknown>;
  const otherEnabled = other.enabled === true;
  if (options.length === 0 && !otherEnabled) return null;
  const trigger = (r.trigger && typeof r.trigger === 'object' ? r.trigger : {}) as Record<string, unknown>;
  const ordered = orderOptions(options, r.randomize === true, rand);
  return {
    survey: {
      version: typeof r.version === 'number' && r.version >= 1 ? Math.floor(r.version) : 1,
      title: typeof r.title === 'string' && r.title ? r.title : 'Why are you leaving?',
      options: ordered,
      otherEnabled,
      otherPlaceholder:
        typeof other.placeholder === 'string' && other.placeholder ? other.placeholder : 'Tell us more',
      shownOrder: shownOrder(ordered, otherEnabled),
    },
    autoRenewTrigger: trigger.onAutoRenewOff !== false,
    maxPerUserDays:
      typeof trigger.maxPerUserDays === 'number' ? trigger.maxPerUserDays : DEFAULT_MAX_PER_USER_DAYS,
    sampleRate: typeof r.sampleRate === 'number' ? r.sampleRate : 1,
  };
}

/** UTC day key, "yyyy-mm-dd". */
export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}
