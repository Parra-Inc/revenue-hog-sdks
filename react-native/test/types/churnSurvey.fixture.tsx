// Type-level test: compiled by `npm run test:types` against the built
// declarations, as an app would consume them. Fails on TS2786 if the
// components stop being valid JSX element types.
import RevenueHog, { ChurnSurveyHost, ChurnSurveySheet } from '../../dist/index';
import type { ChurnSurveyResult } from '../../dist/index';

export function App() {
  return (
    <>
      <ChurnSurveyHost />
      <ChurnSurveyHost locale="de" labels={{ send: 'Senden' }} />
      <ChurnSurveySheet survey={null} onFinish={(_result: ChurnSurveyResult) => undefined} />
    </>
  );
}

export const installId: Promise<string> = RevenueHog.getInstallId();
