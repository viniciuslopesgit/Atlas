# Tests and publishing

Nothing is committed, pushed or published without passing the tests.

```bash
Atlas/scripts/install-hooks.sh            # once: turns on the git hooks
Atlas/scripts/test.sh                     # unit tests (swift test)
Atlas/scripts/test-isolated.sh            # every test inside the proven sandbox
Atlas/scripts/check.sh                    # quick check
Atlas/scripts/check.sh --full             # full check
Atlas/scripts/ship.sh "feat: message"     # new version if the app changed → full check → commit → push dev → beta
Atlas/scripts/bump_version.sh [kind]      # create the version yourself, to write its CHANGELOG section by hand
Atlas/scripts/stable.sh                   # which version should be stable, and why
```

- **Quick check** (before each commit, through the `pre-commit` hook): script syntax and script tests, no keys or secret files, sensitive code only in the reviewed files, new files in `Sources/` come with tests, warning-free build, every test inside the sandbox, and minimum coverage of the critical files.
- **Full check** (before each push, through the `pre-push` hook, in `ship.sh` and in CI): all of the above, the version's CHANGELOG section filled in, no change to a version already published, a universal signed app, and the self-test of the built app.
- **Releases are automatic.** The version lives in `Atlas/Resources/Info.plist`. When `ship.sh` sees that the app changed after the published version, it creates the next one (`bump_version.sh --auto`): the kind comes from the Conventional Commits (`feat:` → minor, `fix:` → patch, `!` → major), and the `CHANGELOG.md` section is written from them, with a summary line. To word it for users yourself, run `bump_version.sh` first and edit the section. A change merged on GitHub gets its version from the `version` job in CI, which commits it and runs CI again. After `ship.sh` pushes to `dev`, CI runs the full check on macOS 14 and 15 and publishes the `X.Y.Z` Release as a beta, with `Atlas-X.Y.Z.zip`, `SHA256SUMS` and the notes from the CHANGELOG (`release_notes.sh`).
- **Stable versions are approved automatically.** `promote.yml` runs `Atlas/scripts/stable.sh --apply` every 6 hours: the most recent beta that meets the [release criteria](RELEASE_CRITERIA.md) is approved by those rules, verified again in a clean copy and promoted to `main` through a Pull Request; its Release is published as stable (**Latest**) with the notes of its CHANGELOG section and the reason it was approved. Nobody has to approve: a new major version waits 72 h instead of 24 h (`gh workflow run promote.yml --ref dev -f approve=X.Y.Z` approves it after 24 h).
- **Stopping a release.** Open an issue with the `hold-release` label: it holds the version it names (`2.1.0`), or every version when it names none. Close it to let the promotion continue. An open `bug` issue that names a version holds it too. `stable.sh` shows why each version is or is not stable; `--check X.Y.Z` only verifies, `--dry-run X.Y.Z` rehearses without pushing.

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
