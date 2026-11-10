import { afterEach, describe, expect, it } from 'vitest';
import RevenueHog from '../src/index';
import {
  builtInChurnSurveyPresenter,
  canSendChurnSurvey,
  churnSurveyResultFor,
  isChurnSurveyHostMounted,
  registerChurnSurveyHost,
} from '../src/ChurnSurveySheet';
import { CHURN_SURVEY_LABELS, churnSurveyLabelLocale, churnSurveyLabels } from '../src/churnSurveyLabels';
import { memoryStorage } from '../src/storage';
import type { ChurnSurvey, FetchLike } from '../src/types';

const survey: ChurnSurvey = {
  version: 2,
  title: 'Why are you leaving?',
  options: [{ key: 'too_expensive', title: 'Too expensive' }],
  otherEnabled: true,
  otherPlaceholder: 'Tell us more',
  allowAdditionalInfo: false,
  shownOrder: ['too_expensive', 'other'],
};

describe('churn survey labels', () => {
  it('maps locales to the bundled table', () => {
    expect(churnSurveyLabelLocale('de_AT')).toBe('de');
    expect(churnSurveyLabelLocale('pt-BR')).toBe('pt-BR');
    expect(churnSurveyLabelLocale('pt_PT')).toBe('pt');
    expect(churnSurveyLabelLocale('zh-Hant-TW')).toBe('zh-Hant');
    expect(churnSurveyLabelLocale('zh_TW')).toBe('zh-Hant');
    expect(churnSurveyLabelLocale('zh-CN')).toBe('zh-Hans');
    expect(churnSurveyLabelLocale('xx')).toBe('en');
    expect(churnSurveyLabelLocale(undefined)).toBe('en');
  });

  it('localizes and lets overrides win field by field', () => {
    const additionalInfo = 'Dites-nous en plus (facultatif)';
    expect(churnSurveyLabels('fr')).toEqual({ other: 'Autre', skip: 'Passer', send: 'Envoyer', additionalInfo });
    expect(churnSurveyLabels('fr', { send: 'Go', skip: '' })).toEqual({ other: 'Autre', skip: 'Passer', send: 'Go', additionalInfo });
    expect(churnSurveyLabels('en').additionalInfo).toBe('Tell us more (optional)');
  });

  it('every locale has every label', () => {
    expect(Object.keys(CHURN_SURVEY_LABELS)).toHaveLength(17);
    for (const labels of Object.values(CHURN_SURVEY_LABELS)) {
      expect(labels.other && labels.skip && labels.send && labels.additionalInfo).toBeTruthy();
    }
  });
});

describe('churn survey sheet logic', () => {
  it('enables Send only for a real answer', () => {
    expect(canSendChurnSurvey(null, '')).toBe(false);
    expect(canSendChurnSurvey('too_expensive', '')).toBe(true);
    expect(canSendChurnSurvey('other', '  ')).toBe(false);
    expect(canSendChurnSurvey('other', 'meh')).toBe(true);
  });

  it('builds the result like the native SDKs', () => {
    expect(churnSurveyResultFor('too_expensive', '')).toEqual({ type: 'option', key: 'too_expensive' });
    expect(churnSurveyResultFor('other', ' meh ')).toEqual({ type: 'other', text: 'meh' });
    expect(churnSurveyResultFor('other', ' ')).toEqual({ type: 'skipped' });
    expect(churnSurveyResultFor(null, '')).toEqual({ type: 'skipped' });
  });

  it('attaches additional info to any answer, never to a skip', () => {
    expect(churnSurveyResultFor('too_expensive', '', ' yearly please ')).toEqual({
      type: 'option',
      key: 'too_expensive',
      additionalInfo: 'yearly please',
    });
    expect(churnSurveyResultFor('other', 'meh', 'more')).toEqual({ type: 'other', text: 'meh', additionalInfo: 'more' });
    expect(churnSurveyResultFor('too_expensive', '', '   ')).toEqual({ type: 'option', key: 'too_expensive' });
    expect(churnSurveyResultFor(null, '', 'x')).toEqual({ type: 'skipped' });
  });
});

describe('built-in presenter', () => {
  let unregister: (() => void) | undefined;
  afterEach(() => {
    unregister?.();
    unregister = undefined;
  });

  it('is notShown without a mounted host', async () => {
    expect(isChurnSurveyHostMounted()).toBe(false);
    await expect(builtInChurnSurveyPresenter(survey)).resolves.toEqual({ type: 'notShown' });
  });

  it('presentChurnSurvey falls back to the mounted host and records the answer', async () => {
    const posted: { url: string; body?: string }[] = [];
    const fetchFn: FetchLike = async (url, init) => {
      posted.push({ url, body: init.body });
      if (init.method === 'GET') {
        return {
          status: 200,
          text: async () =>
            JSON.stringify({
              show: true,
              survey: {
                version: 2,
                title: 'Why?',
                options: [{ key: 'too_expensive', title: 'Too expensive' }],
                other: { enabled: true },
              },
            }),
        };
      }
      return { status: 200 };
    };
    RevenueHog.configure({
      baseUrl: 'https://example.test',
      bundleId: 'com.example.app',
      storage: memoryStorage(),
      logLevel: 'silent',
      fetch: fetchFn,
      autoAttribution: false,
      churnSurveyAutoTrigger: false,
    });
    const shown: ChurnSurvey[] = [];
    unregister = registerChurnSurveyHost(async (s) => {
      shown.push(s);
      return { type: 'option', key: 'too_expensive' };
    });

    await expect(RevenueHog.presentChurnSurvey()).resolves.toEqual({ type: 'option', key: 'too_expensive' });
    expect(shown[0]?.title).toBe('Why?');
    const answer = posted.find((p) => p.url.endsWith('/api/sdk/v1/churn-survey/response'));
    expect(JSON.parse(answer?.body ?? '{}').optionKey).toBe('too_expensive');
  });
});
