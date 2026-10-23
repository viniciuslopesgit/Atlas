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

Download `Atlas-X.Y.Z.zip` from the [latest release](https://github.com/viniciuslopesgit/Atlas/releases/latest), unzip it and drag `Atlas.app` to Applications. Check the download with `shasum -a 256 -c SHA256SUMS`.
Betas (new versions not yet stable) appear as *pre-releases*.

> The app is not notarized: the first time, allow it in *System Settings ▸ Privacy & Security ▸ Open Anyway*.

To keep it up to date automatically (every new release, betas included), run `Atlas/scripts/install-updater.sh` once — details in [Atlas/README.md](Atlas/README.md#automatic-updates-on-this-mac).

## Development

```bash
Atlas/scripts/install-hooks.sh          # once per clone: pre-commit, commit-msg and pre-push hooks
cd Atlas && swift run                   # run in development
Atlas/scripts/check.sh                  # quick check: build without warnings, every test in a sandbox, coverage
Atlas/scripts/bump_version.sh           # next version and its CHANGELOG section
Atlas/scripts/ship.sh "feat: message"   # full check → commit → push dev → GitHub publishes the beta
```

Needs Swift 5.9+; the Xcode Command Line Tools are enough. To open in Xcode: `open Atlas/Package.swift`.
How tests, versions and releases work: [docs/development.md](docs/development.md) and [docs/RELEASE_CRITERIA.md](docs/RELEASE_CRITERIA.md). How to contribute: [CONTRIBUTING.md](CONTRIBUTING.md). Vulnerabilities: [SECURITY.md](SECURITY.md).

## Branch flow and releases

```
change ──► bump_version.sh ──► ship.sh: full check ──► commit ──► push dev
                                                                    │  CI: full check on macOS 14 and 15
                                                                    ▼
                                                      beta Release X.Y.Z (pre-release, zip + SHA256SUMS)
                                                                    │  24 h, CI green, no open bugs, no later fixes
                                                                    ▼
                                    promote.yml: verified again ──► Pull Request ──► main + Release "Latest"
```

- **`dev`** receives every change. [`ci.yml`](.github/workflows/ci.yml) runs [`check.sh --full`](Atlas/scripts/check.sh) on macOS 14 and 15 and publishes a version that has no Release yet as a beta, with the notes from its [`CHANGELOG.md`](CHANGELOG.md) section.
- **`main`** only has the stable version, without tests or development scripts ([`.mainignore`](.mainignore)). [`promote.yml`](.github/workflows/promote.yml) runs daily and promotes the newest beta that meets the [release criteria](docs/RELEASE_CRITERIA.md); a new major version needs `approve=X.Y.Z`.
- **Versions** live in [`Atlas/Resources/Info.plist`](Atlas/Resources/Info.plist) and change only through `bump_version.sh`, which suggests the kind from the Conventional Commits (`feat:` → minor, `fix:` → patch, `feat!:` → major) and prefills the CHANGELOG section to rewrite. A published version never changes: the full check refuses it.

## Repository layout

| Path | Contents |
|---|---|
| [`Atlas/`](Atlas/) | The macOS app (Swift Package) — architecture in [Atlas/README.md](Atlas/README.md) |
| [`cloud-atlas.io/`](cloud-atlas.io/) | Website, published by `deploy-site.yml` |
| [`.githooks/`](.githooks/) | `pre-commit`, `commit-msg` and `pre-push` |
| [`docs/`](docs/) | Development, release criteria and risk register |
| [`.github/workflows/`](.github/workflows/) | `ci.yml`, `promote.yml`, `deploy-site.yml` |

## License

[MIT](LICENSE) © 2026 Vinicius Lopes
