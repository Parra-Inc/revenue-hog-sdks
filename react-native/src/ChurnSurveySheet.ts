/**
 * Optional built-in churn survey UI for React Native: a modal sheet with the
 * options in the order the server sent them (shuffled when the dashboard
 * says so), "Other" last with a text field, an optional additional info
 * field when the survey allows it, and Skip / Send, matching the
 * Swift and Kotlin SDKs.
 *
 * `react` and `react-native` are optional peer dependencies and are only
 * required when one of these components actually renders, so headless use
 * of the SDK (no React at all) keeps working. No JSX, so the package build
 * needs no React types.
 */
import { churnSurveyLabels, type ChurnSurveyLabels } from './churnSurveyLabels';
import { OTHER_KEY } from './churnSurvey';
import type { ChurnSurvey, ChurnSurveyPresenter, ChurnSurveyResult } from './types';

// Minimal shapes of the React and React Native APIs used here.
type Element = unknown;
type CreateElement = (type: unknown, props?: Record<string, unknown> | null, ...children: unknown[]) => Element;
interface ReactLike {
  createElement: CreateElement;
  useState<S>(initial: S): [S, (next: S) => void];
  useEffect(effect: () => void | (() => void), deps?: unknown[]): void;
}
interface ReactNativeLike {
  Modal: unknown;
  View: unknown;
  Text: unknown;
  TextInput: unknown;
  Pressable: unknown;
  ScrollView: unknown;
  KeyboardAvoidingView: unknown;
  Platform: { OS: string };
  useColorScheme?: () => string | null | undefined;
}

function react(): ReactLike {
  return require('react') as ReactLike;
}
function reactNative(): ReactNativeLike {
  return require('react-native') as ReactNativeLike;
}

/** True when Send should be enabled for this selection. */
export function canSendChurnSurvey(selection: string | null, otherText: string): boolean {
  if (selection == null) return false;
  if (selection === OTHER_KEY) return otherText.trim().length > 0;
  return true;
}

/**
 * The result Send produces for this selection. `additionalInfo` rides along
 * with an answer when it is not blank; pass '' when the survey does not
 * allow it.
 */
export function churnSurveyResultFor(
  selection: string | null,
  otherText: string,
  additionalInfo = ''
): ChurnSurveyResult {
  if (selection == null) return { type: 'skipped' };
  const extra = additionalInfo.trim();
  const withExtra = extra ? { additionalInfo: extra } : {};
  if (selection === OTHER_KEY) {
    const text = otherText.trim();
    return text ? { type: 'other', text, ...withExtra } : { type: 'skipped' };
  }
  return { type: 'option', key: selection, ...withExtra };
}

export interface ChurnSurveySheetProps {
  /** The survey to show, or null to keep the sheet hidden. */
  survey: ChurnSurvey | null;
  /** Called once with the answer, or `{ type: 'skipped' }`. */
  onFinish: (result: ChurnSurveyResult) => void;
  /** Override any of the bundled labels ("Other", "Skip", "Send", additional info). */
  labels?: Partial<ChurnSurveyLabels>;
  /** Locale for the bundled labels. Defaults to the device locale. */
  locale?: string;
}

/**
 * The survey sheet as a controlled component: render it anywhere, pass the
 * survey to show and handle `onFinish`. Most apps mount `<ChurnSurveyHost />`
 * instead, which wires this sheet to `RevenueHog.presentChurnSurvey()`.
 */
export function ChurnSurveySheet(props: ChurnSurveySheetProps): Element {
  const React = react();
  const RN = reactNative();
  const h = React.createElement;
  const { survey, onFinish } = props;
  const [selection, setSelection] = React.useState<string | null>(null);
  const [otherText, setOtherText] = React.useState('');
  const [additionalInfo, setAdditionalInfo] = React.useState('');
  const surveyKey = survey ? survey.shownOrder.join('|') + ':' + survey.version : '';
  React.useEffect(() => {
    setSelection(null);
    setOtherText('');
    setAdditionalInfo('');
  }, [surveyKey]);

  const dark = RN.useColorScheme?.() === 'dark';
  const colors = {
    bg: dark ? '#1c1c1e' : '#ffffff',
    text: dark ? '#ffffff' : '#000000',
    muted: dark ? '#8e8e93' : '#6c6c70',
    border: dark ? '#38383a' : '#d1d1d6',
    accent: '#007aff',
  };
  const labels = churnSurveyLabels(props.locale, props.labels);
  const sendEnabled = canSendChurnSurvey(selection, otherText);

  const row = (key: string, title: string): Element => {
    const selected = selection === key;
    return h(
      RN.Pressable,
      {
        key,
        onPress: () => setSelection(key),
        accessibilityRole: 'radio',
        accessibilityState: { selected, checked: selected },
        style: {
          flexDirection: 'row',
          alignItems: 'center',
          paddingVertical: 14,
          borderBottomWidth: 1,
          borderBottomColor: colors.border,
        },
      },
      h(RN.Text, { style: { flex: 1, fontSize: 17, color: colors.text } }, title),
      h(
        RN.View,
        {
          style: {
            width: 22,
            height: 22,
            borderRadius: 11,
            borderWidth: 2,
            borderColor: colors.accent,
            alignItems: 'center',
            justifyContent: 'center',
          },
        },
        selected
          ? h(RN.View, { style: { width: 12, height: 12, borderRadius: 6, backgroundColor: colors.accent } })
          : null
      )
    );
  };

  const button = (title: string, onPress: () => void, enabled: boolean, bold: boolean): Element =>
    h(
      RN.Pressable,
      {
        onPress: enabled ? onPress : undefined,
        disabled: !enabled,
        accessibilityRole: 'button',
        accessibilityState: { disabled: !enabled },
        hitSlop: 10,
      },
      h(
        RN.Text,
        {
          style: {
            fontSize: 17,
            fontWeight: bold ? '600' : '400',
            color: enabled ? colors.accent : colors.muted,
          },
        },
        title
      )
    );

  const content = survey
    ? h(
        RN.KeyboardAvoidingView,
        {
          behavior: RN.Platform.OS === 'ios' ? 'padding' : undefined,
          style: { flex: 1, backgroundColor: colors.bg },
        },
        h(
          RN.View,
          {
            style: {
              flexDirection: 'row',
              alignItems: 'center',
              justifyContent: 'space-between',
              paddingHorizontal: 16,
              paddingVertical: 14,
              borderBottomWidth: 1,
              borderBottomColor: colors.border,
            },
          },
          button(labels.skip, () => onFinish({ type: 'skipped' }), true, false),
          h(
            RN.Text,
            {
              accessibilityRole: 'header',
              numberOfLines: 2,
              style: { flex: 1, textAlign: 'center', fontSize: 17, fontWeight: '600', color: colors.text, marginHorizontal: 12 },
            },
            survey.title
          ),
          button(
            labels.send,
            () =>
              onFinish(
                churnSurveyResultFor(selection, otherText, survey.allowAdditionalInfo ? additionalInfo : '')
              ),
            sendEnabled,
            true
          )
        ),
        h(
          RN.ScrollView,
          { keyboardShouldPersistTaps: 'handled', contentContainerStyle: { paddingHorizontal: 16 } },
          ...survey.options.map((o) => row(o.key, o.title)),
          survey.otherEnabled ? row(OTHER_KEY, labels.other) : null,
          survey.otherEnabled && selection === OTHER_KEY
            ? h(RN.TextInput, {
                value: otherText,
                onChangeText: setOtherText,
                placeholder: survey.otherPlaceholder,
                placeholderTextColor: colors.muted,
                autoFocus: true,
                multiline: true,
                maxLength: 1000,
                style: {
                  marginTop: 12,
                  minHeight: 80,
                  padding: 12,
                  fontSize: 16,
                  color: colors.text,
                  borderWidth: 1,
                  borderColor: colors.border,
                  borderRadius: 10,
                  textAlignVertical: 'top',
                },
              })
            : null,
          survey.allowAdditionalInfo && selection != null
            ? h(RN.TextInput, {
                value: additionalInfo,
                onChangeText: setAdditionalInfo,
                placeholder: labels.additionalInfo,
                placeholderTextColor: colors.muted,
                accessibilityLabel: labels.additionalInfo,
                multiline: true,
                maxLength: 1000,
                style: {
                  marginTop: 12,
                  minHeight: 80,
                  padding: 12,
                  fontSize: 16,
                  color: colors.text,
                  borderWidth: 1,
                  borderColor: colors.border,
                  borderRadius: 10,
                  textAlignVertical: 'top',
                },
              })
            : null
        )
      )
    : null;

  return h(
    RN.Modal,
    {
      visible: survey != null,
      animationType: 'slide',
      presentationStyle: 'pageSheet',
      onRequestClose: () => onFinish({ type: 'skipped' }),
    },
    content
  );
}

// MARK: - Host: wires the sheet to RevenueHog.presentChurnSurvey()

type Show = (survey: ChurnSurvey) => Promise<ChurnSurveyResult>;
let activeHost: Show | null = null;

/** True while a `<ChurnSurveyHost />` is mounted. */
export function isChurnSurveyHostMounted(): boolean {
  return activeHost != null;
}

/**
 * Presenter that shows the survey through the mounted `<ChurnSurveyHost />`.
 * Resolves `{ type: 'notShown' }` when no host is mounted. The SDK uses it
 * automatically when `configure()` has no `churnSurveyPresenter`.
 */
export const builtInChurnSurveyPresenter: ChurnSurveyPresenter = (survey) =>
  activeHost ? activeHost(survey) : Promise.resolve({ type: 'notShown' });

/** Test seam and the host's registration hook. */
export function registerChurnSurveyHost(show: Show | null): () => void {
  activeHost = show;
  return () => {
    if (activeHost === show) activeHost = null;
  };
}

export interface ChurnSurveyHostProps {
  /** Override any of the bundled "Other" / "Skip" / "Send" labels. */
  labels?: Partial<ChurnSurveyLabels>;
  /** Locale for the bundled labels. Defaults to the device locale. */
  locale?: string;
}

/**
 * Mount once near the root of the app. `RevenueHog.presentChurnSurvey()` and
 * the Android auto-renew-off trigger then show the built-in sheet without a
 * custom `churnSurveyPresenter`.
 */
export function ChurnSurveyHost(props: ChurnSurveyHostProps = {}): Element {
  const React = react();
  const [pending, setPending] = React.useState<{
    survey: ChurnSurvey;
    resolve: (r: ChurnSurveyResult) => void;
  } | null>(null);
  React.useEffect(
    () =>
      registerChurnSurveyHost(
        (survey) =>
          new Promise<ChurnSurveyResult>((resolve) => {
            setPending({ survey, resolve });
          })
      ),
    []
  );
  return React.createElement(ChurnSurveySheet, {
    survey: pending?.survey ?? null,
    labels: props.labels,
    locale: props.locale,
    onFinish: (result: ChurnSurveyResult) => {
      const current = pending;
      setPending(null);
      current?.resolve(result);
    },
  });
}
