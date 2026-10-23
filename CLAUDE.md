# Atlas — working rules

Native macOS app (Swift + SwiftUI) in `Atlas/`. Marketing site in `cloud-atlas.io/`.

## Branch flow
- All work goes to **`dev`**. Never commit or push directly to `main`.
- `main` only gets stable versions, from `.github/workflows/promote.yml` (`Atlas/scripts/stable.sh --apply`):
  the newest beta that meets `docs/RELEASE_CRITERIA.md`, verified again, as one commit without the files in `.mainignore`.
- CI (`ci.yml`) runs `check.sh --full` on macOS 14 and 15 and publishes a version without a Release as a beta.

## After every implementation (mandatory)
1. If the app changed: `Atlas/scripts/bump_version.sh [patch|minor|major]` and rewrite the new `CHANGELOG.md`
   section for users (summary paragraph + `### Added/Changed/Fixed/Removed`). Never leave `RELEASE SUMMARY`.
2. `Atlas/scripts/ship.sh "<type>: <message>"` — full check → commit → push dev (`--no-release` when the app did not change).
   Conventional Commits: `feat` `fix` `perf` `refactor` `docs` `test` `build` `ci` `chore` `style` `revert`; `!` for breaking.
3. If the check fails, fix and repeat. Never `--no-verify`, never lower a coverage minimum without saying why.

Hooks are enabled with `Atlas/scripts/install-hooks.sh` (once per clone). The Stop hook in `.claude/` blocks
finishing with unpublished work.

## Mandatory tests
- Every new or changed feature has tests; every fix has a regression test that failed before it.
- Tests only use temporary folders, `MockURLProtocol.client` and `InMemorySecretStore`; they run inside the sandbox
  of `test-isolated.sh`, which fails if they reach the network or write elsewhere.
- New attack surface (network, Keychain, processes, opening files or links, moving or deleting files) ⇒ add the file
  to `REVIEWED` in `check.sh` and an attack test in `SecurityTests.swift`.
- `MIN_COVERAGE` in `check.sh` only goes up.

## Code
- No external dependencies: the AWS client (SigV4, protocols) lives in `Atlas/Sources/Atlas/AWS/`.
- Tests never touch the network or the Keychain: use `MockURLProtocol.client` and `InMemorySecretStore`.
- New service ⇒ new test in `Atlas/Tests/AtlasTests/ServiceTests.swift` with an XML/JSON fixture.
