# Atlas

**Your AWS accounts in one native Mac app.**

The console spreads EC2, S3, IAM and costs across dozens of pages. Atlas brings them into one window — native on macOS, with your credentials stored in the Keychain on your Mac.

- **Costs at a glance** — month to date, end-of-month forecast and the services that weigh most, on the Dashboard and in Billing by month.
- **EC2 without tabs** — start, stop, reboot or terminate several instances at once, see every detail with metrics, and launch new ones with a wizard.
- **S3 like Finder** — browse folders, drag files to upload, follow upload and download progress, and edit text files in place.
- **Security in one click** — IAM (users, roles, groups, policies and access keys), GuardDuty findings, CloudWatch alarms and a quick audit: root MFA, password policy, old keys, IMDSv1 and public S3 buckets.
- **Terraform without leaving the app** — import existing resources into a project, plan and apply what you reviewed, and keep stacks under watch for drift.
- **Multiple accounts, instant switching** — change account or region from the toolbar, and find any resource with ⌘K.

> Requires macOS 14 Sonoma or later. Terraform features need `terraform` 1.5+; EC2 › Connect needs the Session Manager plugin.

---

## Installation

Download `Atlas-X.Y.Z.zip` from the [latest release](https://github.com/viniciuslopesgit/Atlas/releases/latest), unzip it and drag `Atlas.app` to Applications.
Development builds (`X.Y.Z-dev.N`) appear as *pre-releases*.

> The app has an ad-hoc signature: the first time, open it with right-click → **Open**.

To keep it up to date automatically (every new release, dev builds included), run `Atlas/scripts/install-updater.sh` once — details in [Atlas/README.md](Atlas/README.md#automatic-updates-on-this-mac).

## Development

```bash
cd Atlas
./scripts/install-hooks.sh          # once per clone: commit-msg + pre-push hooks
swift run                           # run in development
./scripts/test-isolated.sh --smoke  # build + tests + smoke test in an isolated environment
./scripts/build-app.sh              # dist/Atlas.app with the version computed from commits
```

Needs Swift 5.9+; the Xcode Command Line Tools are enough. To open in Xcode: `open Atlas/Package.swift`.

### Tests

| Command | What it does |
|---|---|
| `scripts/test.sh` | Unit tests (`swift test`) in the local tree |
| `scripts/test-isolated.sh` | Temporary copy of the tree, its own `HOME`/`TMPDIR`/build, `sandbox-exec` with no external network and writes only in the temporary folder |
| `scripts/test-isolated.sh --smoke` | The above + opens the app in `ATLAS_SMOKE_TEST` mode and checks the window |
| `scripts/snapshots.sh [folder]` | Renders the dashboard and components (light and dark) with fixture data to PNG, for design review |

Tests never use the network or the Keychain: AWS responses come from fixtures (`MockURLProtocol`) and secrets live in memory.

## Branch flow and releases

```
feature ──► commit (Conventional Commits) ──► pre-push: isolated tests ──► dev
                                                                            │  CI: build, tests, smoke, pre-release X.Y.Z-dev.N
                                                     24h without commits on dev ▼
                                         promote.yml: production pipeline ──► main + stable release X.Y.Z
```

- **`dev`** receives every implementation. Each push triggers [`ci.yml`](.github/workflows/ci.yml).
- **`main`** only receives promotions. [`promote.yml`](.github/workflows/promote.yml) runs daily at 06:00 UTC. When dev has had no new commits for 24h and CI is green, it re-runs the full pipeline from a clean checkout, adds the release to [`CHANGELOG.md`](CHANGELOG.md), fast-forwards `main` and publishes the release. It can also be run manually, with `dry_run`.
- **Releases on GitHub** are automatic: every push to `dev` publishes a pre-release `X.Y.Z-dev.N` with its notes, and every promotion publishes the stable `X.Y.Z` (marked *latest*) with its CHANGELOG section. Nothing is versioned, tagged or written to the changelog by hand.

### Versioning

The version is computed from commits since the last stable tag ([`scripts/version.sh`](Atlas/scripts/version.sh)):

| Commit | Effect |
|---|---|
| `feat: …` | minor (2.**1**.0) |
| `fix: …` / `perf: …` | patch (2.0.**1**) |
| `feat!: …` or `BREAKING CHANGE:` | major (**3**.0.0) |
| `docs:`, `ci:`, `chore:`… | patch, when there is no feat/fix |

`version.sh --next` shows the next stable version, `--dev` the pre-release and `--notes` the release notes. [`scripts/changelog.sh`](Atlas/scripts/changelog.sh) writes `CHANGELOG.md` from the same commits (`--release X.Y.Z`, `--rebuild`, `--check`).

## Repository layout

| Path | Contents |
|---|---|
| [`Atlas/`](Atlas/) | The macOS app (Swift Package) — architecture in [Atlas/README.md](Atlas/README.md) |
| [`cloud-atlas.io/`](cloud-atlas.io/) | Website, published by `deploy-site.yml` |
| [`.githooks/`](.githooks/) | `commit-msg` and `pre-push` |
| [`.github/workflows/`](.github/workflows/) | `ci.yml`, `promote.yml`, `deploy-site.yml` |
