# Atlas — working rules

Native macOS app (Swift + SwiftUI) in `Atlas/`. Marketing site in `cloud-atlas.io/`.

## Branch flow
- All work goes to **`dev`**. Never commit or push directly to `main`.
- `main` only receives promotions from `dev`, done by `.github/workflows/promote.yml`:
  after **24h without new commits on dev** and with CI green, it commits the new section of
  `CHANGELOG.md`, fast-forwards `main` (and `dev`) to it, tags `X.Y.Z` and publishes the release.
- CI runs on GitHub Actions (`ci.yml`): every push to dev publishes a pre-release `X.Y.Z-dev.N`.
- Never edit `CHANGELOG.md`, tags or releases by hand: `Atlas/scripts/changelog.sh` generates them from commits.

## After every implementation (mandatory)
1. `Atlas/scripts/test-isolated.sh --smoke` — build + tests + smoke test in an isolated environment (temporary copy, sandbox with no network). It must pass.
2. Commit in **Conventional Commits** format (the `commit-msg` hook validates it):
   - `feat:` new feature → minor · `fix:`/`perf:` → patch · `feat!:` or `BREAKING CHANGE:` → major
   - other types: `refactor docs test build ci chore style revert`
3. `git push origin dev` (the `pre-push` hook runs the isolated tests again).

Hooks are enabled with `Atlas/scripts/install-hooks.sh` (once per clone).

## Versioning
- Computed from commits, never by hand: `Atlas/scripts/version.sh [--next|--dev|--notes]`.
- Stable tags `X.Y.Z` (only on `main`); CI pre-releases `X.Y.Z-dev.N` (from `dev`).

## Code
- No external dependencies: the AWS client (SigV4, protocols) lives in `Atlas/Sources/Atlas/AWS/`.
- Tests never touch the network or the Keychain: use `MockURLProtocol.client` and `InMemorySecretStore`.
- New service ⇒ new test in `Atlas/Tests/AtlasTests/ServiceTests.swift` with an XML/JSON fixture.
