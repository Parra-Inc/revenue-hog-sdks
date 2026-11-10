/**
 * Labels for the built-in churn survey ("Other", "Skip", "Send" and the
 * optional additional info placeholder).
 * The same strings ship in the Swift (Bundle.module .strings) and Kotlin
 * (res/values-xx) SDKs so the three built-in surveys read the same.
 * The server payload does not carry these labels today; the survey title,
 * option titles and "Other" placeholder come localized from the server.
 */
export interface ChurnSurveyLabels {
  other: string;
  skip: string;
  send: string;
  /** Placeholder for the optional additional info field. */
  additionalInfo: string;
}

export const CHURN_SURVEY_LABELS: Record<string, ChurnSurveyLabels> = {
  en: { other: 'Other', skip: 'Skip', send: 'Send', additionalInfo: 'Tell us more (optional)' },
  ar: { other: 'أخرى', skip: 'تخطي', send: 'إرسال', additionalInfo: 'أخبرنا بالمزيد (اختياري)' },
  de: { other: 'Andere', skip: 'Überspringen', send: 'Senden', additionalInfo: 'Erzählen Sie uns mehr (optional)' },
  es: { other: 'Otro', skip: 'Omitir', send: 'Enviar', additionalInfo: 'Cuéntanos más (opcional)' },
  fr: { other: 'Autre', skip: 'Passer', send: 'Envoyer', additionalInfo: 'Dites-nous en plus (facultatif)' },
  it: { other: 'Altro', skip: 'Salta', send: 'Invia', additionalInfo: 'Dicci di più (facoltativo)' },
  ja: { other: 'その他', skip: 'スキップ', send: '送信', additionalInfo: '詳しく教えてください（任意）' },
  ko: { other: '기타', skip: '건너뛰기', send: '보내기', additionalInfo: '자세히 알려주세요 (선택 사항)' },
  nl: { other: 'Anders', skip: 'Overslaan', send: 'Verzenden', additionalInfo: 'Vertel ons meer (optioneel)' },
  pl: { other: 'Inne', skip: 'Pomiń', send: 'Wyślij', additionalInfo: 'Powiedz nam więcej (opcjonalnie)' },
  'pt-BR': { other: 'Outro', skip: 'Pular', send: 'Enviar', additionalInfo: 'Conte mais para nós (opcional)' },
  pt: { other: 'Outro', skip: 'Ignorar', send: 'Enviar', additionalInfo: 'Diga-nos mais (opcional)' },
  ru: { other: 'Другое', skip: 'Пропустить', send: 'Отправить', additionalInfo: 'Расскажите подробнее (необязательно)' },
  sv: { other: 'Annat', skip: 'Hoppa över', send: 'Skicka', additionalInfo: 'Berätta mer (valfritt)' },
  tr: { other: 'Diğer', skip: 'Atla', send: 'Gönder', additionalInfo: 'Biraz daha anlatın (isteğe bağlı)' },
  'zh-Hans': { other: '其他', skip: '跳过', send: '发送', additionalInfo: '详细说说（选填）' },
  'zh-Hant': { other: '其他', skip: '略過', send: '傳送', additionalInfo: '詳細說說（選填）' },
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
    additionalInfo: overrides?.additionalInfo || base.additionalInfo,
    send: overrides?.send || base.send,
  };
}
