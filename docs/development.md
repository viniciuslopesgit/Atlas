# Tests and publishing

Nothing is committed, pushed or published without passing the tests.

```bash
Atlas/scripts/install-hooks.sh            # once: turns on the git hooks
Atlas/scripts/test.sh                     # unit tests (swift test)
Atlas/scripts/test-isolated.sh            # every test inside the proven sandbox
Atlas/scripts/check.sh                    # quick check
Atlas/scripts/check.sh --full             # full check
Atlas/scripts/bump_version.sh [kind]      # new version (patch, minor or major) and its CHANGELOG section
Atlas/scripts/ship.sh "feat: message"     # full check → commit → push dev → GitHub publishes the beta
Atlas/scripts/stable.sh                   # which version should be stable, and why
```

- **Quick check** (before each commit, through the `pre-commit` hook): script syntax and script tests, no keys or secret files, sensitive code only in the reviewed files, new files in `Sources/` come with tests, warning-free build, every test inside the sandbox, and minimum coverage of the critical files.
- **Full check** (before each push, through the `pre-push` hook, in `ship.sh` and in CI): all of the above, the version's CHANGELOG section filled in, no change to a version already published, a universal signed app, and the self-test of the built app.
- **Releases.** The version lives in `Atlas/Resources/Info.plist` and only changes through `bump_version.sh`, which also opens the version's section in `CHANGELOG.md`, prefilled from the commits since the last release. Rewrite it for people who use Atlas: a summary paragraph (it opens the Release) and the `### Added / Changed / Fixed / Removed` lists. After `ship.sh` pushes to `dev`, CI runs the full check on macOS 14 and 15 and publishes the `X.Y.Z` Release as a beta, with `Atlas-X.Y.Z.zip`, `SHA256SUMS` and the notes from the CHANGELOG (`release_notes.sh`).
- **Stable.** `promote.yml` runs `Atlas/scripts/stable.sh --apply` every day: the most recent beta that meets the [release criteria](RELEASE_CRITERIA.md) is verified again in a clean copy and promoted to `main` through a Pull Request; its Release becomes **Latest**. A new major version needs approval: run the workflow with `approve=X.Y.Z` (`gh workflow run promote.yml --ref dev -f approve=X.Y.Z`). `--check X.Y.Z` only verifies, `--dry-run X.Y.Z` rehearses without pushing.

## What goes to main

`main` only has what is needed to build and distribute the stable version: no tests, hooks or publishing scripts. The list of what is left out is in [`.mainignore`](../.mainignore). Each stable version reaches `main` as a single "Atlas X.Y.Z (stable version)" commit, with the content of the `X.Y.Z` tag without those files.

## Rules for tests

- A new or changed feature comes with tests; a fix comes with a test that failed before it.
- Tests never touch the network or the Keychain: `MockURLProtocol.client` and `InMemorySecretStore`. They only write in temporary folders. The sandbox enforces it.
- A new service comes with a test in `Atlas/Tests/AtlasTests/ServiceTests.swift` and an XML or JSON fixture.
- Code that reaches the network, the Keychain, runs a program, opens a file or link, or moves or deletes files only lives in the files listed in `REVIEWED` (`check.sh`). A new place needs an attack test in `SecurityTests.swift`.
- Coverage minimums (`MIN_COVERAGE` in `check.sh`) only go up.

## Criteria and risks

- [RELEASE_CRITERIA.md](RELEASE_CRITERIA.md): states of a version, quality gates and who decides.
- [RISK_REGISTER.md](RISK_REGISTER.md): known risks, priority and state.
