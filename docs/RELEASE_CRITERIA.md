# Release and stability criteria

An Atlas version is only **stable** when there is verifiable evidence of it. Building, passing the tests or working on the author's Mac is not enough: Atlas holds AWS credentials and can change or delete real infrastructure, and a bug can cost its users money or data.

This document defines the states of a version, what it takes to move from one to the next, how it is measured and who decides. The automatic rules are in [`Atlas/scripts/stable.py`](../Atlas/scripts/stable.py) (with tests in `Atlas/scripts/tests`) and the checks in [`Atlas/scripts/check.sh`](../Atlas/scripts/check.sh). Known risks are in the [risk register](RISK_REGISTER.md).

## 1. Four different things

| Claim | What it proves | What it does **not** prove |
|---|---|---|
| The tests pass | The tested behaviour is as expected on the machines where they ran | That there are no bugs; what is not tested (most AWS responses are fixtures, not real accounts) |
| Functionally correct | Each feature does what it promises, including edge cases and AWS errors | That it works on other macOS versions, accounts with other permissions, or in the long run |
| Operationally reliable | Works on several machines and macOS versions, recovers from failures and throttling | That it is safe in the hands of someone who does not know what a change does |
| Safe for the public | No credential leaves the Keychain except to sign requests, nothing is changed in AWS without confirmation, files stay where the user put them | Total absence of defects |

## 2. States of a version

| State | Where it is | How it gets there | Who decides |
|---|---|---|---|
| **Alpha** | Untagged commits on `dev`; local builds | Quick check in the pre-commit hook | Whoever commits |
| **Beta** | GitHub Release marked as pre-release, with `Atlas-X.Y.Z.zip` and `SHA256SUMS` | `Atlas/scripts/ship.sh`: new version when the app changed → local full check → commit → push `dev` → CI full check on macOS 14 and 15 → `X.Y.Z` tag and Release. A change merged on GitHub gets its version from CI's `version` job | Automatic |
| **Candidate (RC)** | The beta that `stable.sh` points to as candidate | Every automatic criterion in section 3.3 met | Automatic |
| **Stable** | "Atlas X.Y.Z (stable version)" commit on `main`; Release published as stable (**Latest**), with the stable notes | `promote.yml` (every 6 h) runs `Atlas/scripts/stable.sh --apply`: new full check in a clean copy of the tag, build and self-test of `main`'s content, Pull Request with merge | Automatic for every version: the rules approve it. A person can only stop it, with a `hold-release` issue |

The README's download link points to **Latest**, which is always the latest stable. Betas only show to those who look for them; the automatic updater on the maintainer's Mac installs betas too.

### Version types (SemVer)

| Type | When | Requires |
|---|---|---|
| Patch `X.Y.Z+1` | Fixes and internal changes, no new feature | Automatic criteria |
| Minor `X.Y+1.0` | Compatible new feature | Automatic criteria + tests of the new feature in the same commit |
| Major `X+1.0.0` | Incompatible change (stored settings, default behaviour towards AWS, system requirements) | Automatic criteria + 72 h as a beta instead of 24 h (`STABLE_MAJOR_SOAK_HOURS`); the approval is recorded in the Pull Request and the Release. `approve=X.Y.Z` in `promote.yml` (or `STABLE_APPROVE`) approves it after 24 h |

`Atlas/scripts/version.sh --suggest` reads the Conventional Commits since the last release (and the one being shipped) and says which kind the next version is; `ship.sh` and CI use it to create the version on their own (`bump_version.sh --auto`), with a CHANGELOG section written from the commits. Commits scoped `ci`, `release`, `build`, `test`, `docs` or `scripts` stay out of it.

## 3. Quality gates

**B** = blocks, **W** = warning only. "Evidence": what is kept to justify the decision.

### 3.1 On every commit (`check.sh`, pre-commit hook)

| # | Check | Type | Evidence |
|---|---|---|---|
| Q1 | Syntax and execute permission of every script and hook | B | Check output |
| Q2 | Tests of the publishing scripts (`Atlas/scripts/tests`) and the updater's self-test | B | `.build/check-scripts.log` |
| Q3 | No AWS access key or private key in the changes, no secret files tracked, no ignored file tracked, MIT `LICENSE` present | B | Check output |
| Q4 | Network, Keychain, processes, opening files or links, moving and deleting files only in the reviewed files (`REVIEWED` in `check.sh`); tests never use the real Keychain, network or home folder | B | Check output |
| Q5 | A new file in `Sources/` requires new or changed tests | B | Check output |
| Q6 | Warning-free build (`-warnings-as-errors`) | B | `.build/check-build-debug.log` |
| Q7 | Every unit and attack test, 100% passing, serially, inside a sandbox that is first proven to block the network, osascript, sudo, security, open and writes outside its folder (`test-isolated.sh`) | B | `.build/check-tests.log` |
| Q8 | Minimum line coverage of the files that sign requests, hold secrets, write or delete files, run commands or decide what Terraform changes (`MIN_COVERAGE`); minimums only go up | B | `llvm-cov` report |
| Q9 | Skipped tests are listed with their reason | W | Check output |

### 3.2 Before each beta (`check.sh --full`: pre-push hook, `ship.sh`, CI)

| # | Check | Type | Evidence |
|---|---|---|---|
| R1 | Everything in section 3.1 | B | — |
| R2 | `X.Y.Z` version in `Atlas/Resources/Info.plist`, with a filled-in CHANGELOG section and its link | B | CHANGELOG |
| R3 | A published version never changes: if the app changed since its tag, the version must be bumped | B | Check output |
| R4 | Universal app (arm64 + x86_64), signed, right version | B | `lipo`, `codesign --verify` |
| R5 | Self-test of the built release binary: it opens its window with throwaway storage and in-memory secrets, and 5 security checks give the expected result | B | `.build/check-selftest.log` |
| R6 | The same full check on GitHub's macOS 14 and macOS 15 runners | B | CI run |

### 3.3 To become a candidate (`stable.py`)

| # | Criterion | Type |
|---|---|---|
| C1 | Published Release (not a draft) with `Atlas-X.Y.Z.zip` and `SHA256SUMS` | B |
| C2 | The tag is in `dev`'s history and has `.mainignore` | B |
| C3 | Every GitHub check on the tag's commit completed successfully | B |
| C4 | No open issue labelled `bug` mentions the version | B |
| C4b | No open issue labelled `hold-release` mentions the version, or mentions no version at all (stops every promotion) | B |
| C5 | No later version brings fixes (`### Fixed` in the CHANGELOG): the fix becomes the candidate instead | B |
| C6 | Published at least 24 h ago (`STABLE_SOAK_HOURS`). A waiting period, not proof of reliability | B |
| C7 | A new major version has been a beta for 72 h (`STABLE_MAJOR_SOAK_HOURS`), or was approved early with `approve=X.Y.Z` | B |

### 3.4 To become stable (`stable.sh --apply`)

| # | Check | Type |
|---|---|---|
| S1 | The tag's exact commit passes `check.sh --full` again, in a clean copy with no caches | B |
| S2 | `main`'s commit differs from the tag only by the development files of `.mainignore` | B |
| S3 | `main`'s content builds on its own, is signed and passes the self-test | B |
| S4 | It reaches `main` through a Pull Request (or, when GitHub Actions may not open one, as a fast-forward of the same verified commit) | B |

## 4. What a version does not promise

- AWS behaviour is tested against recorded responses, not live accounts. A new AWS API change can break a feature without any test failing.
- The Terraform and SSM features depend on the user's own `terraform` and `session-manager-plugin` binaries.
- The app is not notarized (see [RISK_REGISTER.md](RISK_REGISTER.md), R3).

## 5. Manual checks

Before each minor or major: run the app against a real account with read-only credentials and confirm the dashboard, EC2, S3, IAM and billing pages load; open an SSM session if there is a managed instance; run `terraform plan` on a sample project. Write the result in the Pull Request.
