# Contributing

Thanks for helping make the hog fatter.

## Ground rules

- **Zero runtime dependencies.** Every SDK in this repo ships with no
  third-party runtime deps. PRs that add one will be closed. Optional
  integrations (e.g. `react-native-iap`, Play Billing) must be detected
  lazily and wrapped in try/catch.
- **Never crash the host app.** All SDK errors are swallowed into the debug
  log. If your change can throw across the public API boundary, it's a bug.
- **Small.** Each SDK core stays under ~500 lines. Fight for every line.
- **Tests required.** Queue behavior, payload encoding, and retry/backoff
  paths must be covered with a mocked transport.

## Workflow

1. Fork, branch from `main`.
2. Make your change in exactly one SDK directory (`swift/`, `react-native/`,
   `kotlin/`) unless it's a cross-cutting contract change.
3. Run the relevant test suite:
   - `cd swift && swift test`
   - `cd react-native && npm test && npm run build`
   - `cd kotlin && ./gradlew test`
4. Use conventional commits (`feat(swift): …`, `fix(rn): …`).
5. Open a PR with a short description of the behavior change.

## API contract

The SDKs speak to two endpoints only (`POST /api/sdk/v1/identify`,
`POST /api/sdk/v1/attribute`). Contract changes must land in the backend
first and stay backward compatible — SDKs in the wild update slowly.
