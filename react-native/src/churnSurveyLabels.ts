/**
 * Button labels for the built-in churn survey ("Other", "Skip", "Send").
 * The same strings ship in the Swift (Bundle.module .strings) and Kotlin
 * (res/values-xx) SDKs so the three built-in surveys read the same.
 * The server payload does not carry these labels today; the survey title,
 * option titles and "Other" placeholder come localized from the server.
 */
export interface ChurnSurveyLabels {
  other: string;
  skip: string;
  send: string;
}

export const CHURN_SURVEY_LABELS: Record<string, ChurnSurveyLabels> = {
  en: { other: 'Other', skip: 'Skip', send: 'Send' },
  ar: { other: 'أخرى', skip: 'تخطي', send: 'إرسال' },
  de: { other: 'Andere', skip: 'Überspringen', send: 'Senden' },
  es: { other: 'Otro', skip: 'Omitir', send: 'Enviar' },
  fr: { other: 'Autre', skip: 'Passer', send: 'Envoyer' },
  it: { other: 'Altro', skip: 'Salta', send: 'Invia' },
  ja: { other: 'その他', skip: 'スキップ', send: '送信' },
  ko: { other: '기타', skip: '건너뛰기', send: '보내기' },
  nl: { other: 'Anders', skip: 'Overslaan', send: 'Verzenden' },
  pl: { other: 'Inne', skip: 'Pomiń', send: 'Wyślij' },
  'pt-BR': { other: 'Outro', skip: 'Pular', send: 'Enviar' },
  pt: { other: 'Outro', skip: 'Ignorar', send: 'Enviar' },
  ru: { other: 'Другое', skip: 'Пропустить', send: 'Отправить' },
  sv: { other: 'Annat', skip: 'Hoppa över', send: 'Skicka' },
  tr: { other: 'Diğer', skip: 'Atla', send: 'Gönder' },
  'zh-Hans': { other: '其他', skip: '跳过', send: '发送' },
  'zh-Hant': { other: '其他', skip: '略過', send: '傳送' },
};

const TRADITIONAL_REGIONS = new Set(['TW', 'HK', 'MO']);

/** The table key for a BCP 47 or POSIX locale such as `de_AT` or `zh-Hant-TW`. */
export function churnSurveyLabelLocale(locale: string | undefined | null): string {
  if (!locale) return 'en';
  const parts = locale.replace(/_/g, '-').split('-').filter(Boolean);
  const lang = (parts[0] ?? '').toLowerCase();
  const rest = parts.slice(1);
  if (lang === 'zh') {
    if (rest.some((p) => p.toLowerCase() === 'hant')) return 'zh-Hant';
    if (rest.some((p) => p.toLowerCase() === 'hans')) return 'zh-Hans';
    return rest.some((p) => TRADITIONAL_REGIONS.has(p.toUpperCase())) ? 'zh-Hant' : 'zh-Hans';
  }
  if (lang === 'pt') return rest.some((p) => p.toUpperCase() === 'BR') ? 'pt-BR' : 'pt';
  return lang in CHURN_SURVEY_LABELS ? lang : 'en';
}

/** Device locale through Intl, which Hermes and JSC both provide. */
function deviceLocale(): string | undefined {
  try {
    return Intl.DateTimeFormat().resolvedOptions().locale;
  } catch {
    return undefined;
  }
}

/**
 * Labels for `locale` (the device locale when omitted), English for anything
 * unsupported. `overrides` win over the bundled strings field by field.
 */
export function churnSurveyLabels(
  locale?: string | null,
  overrides?: Partial<ChurnSurveyLabels>
): ChurnSurveyLabels {
  const base = CHURN_SURVEY_LABELS[churnSurveyLabelLocale(locale ?? deviceLocale())] ?? CHURN_SURVEY_LABELS.en!;
  return {
    other: overrides?.other || base.other,
    skip: overrides?.skip || base.skip,
    send: overrides?.send || base.send,
  };
}
