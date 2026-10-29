# Atlas for macOS

Native macOS version of Atlas, written in **Swift + SwiftUI** (macOS 12+).
It replaces the original WPF/.NET version for Windows, which has been removed from this repository.

## Requirements

- macOS 12 Monterey or later
- Swift 5.9+ (the Xcode Command Line Tools are enough; Xcode is optional)

## Build and run

```bash
cd Atlas
swift run                    # development
./scripts/build-app.sh       # creates dist/Atlas.app (universal, ad-hoc signature; UNIVERSAL=0 for this Mac only)
./scripts/test.sh            # unit tests
./scripts/test-isolated.sh   # every test inside a proven sandbox (no network, writes only in its own folder)
./scripts/check.sh           # the quality gate (docs/development.md)
open dist/Atlas.app
```

To open it in Xcode: `open Package.swift`.
To distribute: `SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh`, then notarize.

## Architecture

```
Sources/Atlas/
├── App/        AtlasApp (entry point, menus, shortcuts), AppState (account/region/navigation)
├── AWS/        Own AWS client, no external dependencies:
│               SigV4 (CryptoKit), Query / JSON 1.0 and 1.1 / REST-JSON / REST-XML (S3, Route 53), XML parser
├── Models/     Data structs (EC2, S3, IAM, CloudWatch, GuardDuty, costs…)
├── Services/   Ec2, S3, Iam/Sts (+ write operations), Ssm, CloudWatch, Cost Explorer, GuardDuty, SecurityAudit, Search, Dashboard
├── Storage/    Keychain (secrets) + AccountStore (JSON in ~/Library/Application Support/Atlas)
├── Terraform/  TerraformCLI (runs the terraform binary), HCL templates and ATLAS-MANAGED merge,
│               ImportDiscovery (34 resource types → import blocks), generated-HCL fixer/splitter,
│               env var extractor, projects, Stacks (model, cron, drift report, encrypted store)
└── Views/      SwiftUI: Dashboard, EC2, S3, IAM, CloudWatch, GuardDuty, Audit, Billing,
                Infrastructure as Code, Stacks, Accounts, Feedback, ⌘K search
```

| Windows (.NET)                    | macOS (Swift)                                  |
|-----------------------------------|------------------------------------------------|
| WPF + XAML + MVVM Toolkit         | SwiftUI (`ObservableObject`, `Table`, `Charts`) |
| AWS SDK for .NET                  | Own client with SigV4 (`AWS/`)                 |
| DPAPI + SQLite                    | macOS Keychain + JSON                          |
| Light/Dark theme (XAML)           | System appearance + manual choice (View › Appearance) |

## Features

- **Accounts**: add with STS validation, remove, switch active account, region selector
- **Dashboard**: EC2/S3/alarm KPIs, month-to-date cost, forecast, previous month, daily chart, top services
- **EC2**: list, search, status filter, multi-select, Start/Stop/Reboot/Terminate with confirmation,
  details panel (all fields), CloudWatch metrics, launch wizard, key pair creation, CSV export,
  **Connect** to a running instance with an SSM shell in Terminal
- **S3**: buckets (with region), folder browsing, upload/download with progress, drag & drop,
  create folder, delete (including folders), create/delete bucket, text editor, CSV export
- **IAM**: users, roles, groups, policies; create users (console access, groups, policies, tags, access key);
  delete users, roles, groups and policies with their dependencies; attach/detach policies, group membership,
  tags; access key management; policy document
- **CloudWatch** (alarms), **GuardDuty** (findings), **Security Quick Audit**, **Billing** (Cost Explorer)
- **Infrastructure as Code**: Terraform projects with init, validate, plan, apply (only the reviewed plan)
  and output, live output; **Import from AWS** for 34 resource types → `imports.tf` + Atlas templates →
  `plan -generate-config-out` → fixes → one file per service. Launching an instance or creating a bucket
  also adds it, with its import block, to the active project.
- **Stacks**: run history, scheduled drift checks (interval or cron) with notifications, Fix Drift with the
  saved plan, optional auto-fix, import into an S3 remote state (`atlas-tfstate-<account>`), variables in
  the Keychain
- **Feedback**: opens Mail with the message ready, or copies it as a GitHub issue
- **⌘K search** across pages, EC2, S3 and IAM
- **Updates**: Help › Check for Updates… and the status in Accounts (see below)

Shortcuts: ⌘R refresh · ⌘K search · ⌘1…⌘9 the first nine pages.

## Outside tools

Atlas calls these only when you use the feature that needs them, and tells you how to install them:

| Feature | Tool | Install |
|---|---|---|
| Infrastructure as Code, Stacks | `terraform` 1.5+ | `brew install terraform` |
| Automatic updates | `gh`, signed in | `brew install gh && gh auth login` |

Credentials reach `terraform` only through the child process's environment; they are never written to `.tf`
files or passed on a command line.

EC2 › Connect needs nothing extra: Atlas speaks the Session Manager protocol itself and opens the shell in
Terminal. KMS-encrypted sessions (a Session Manager preference) are not supported yet.

## Automatic updates on this Mac

```bash
Atlas/scripts/install-updater.sh             # once
Atlas/scripts/install-updater.sh --uninstall # to remove it
```

It installs a LaunchAgent that checks GitHub every 10 minutes and replaces `/Applications/Atlas.app` with the
newest release, betas included, after checking it against `SHA256SUMS` (it quits and reopens Atlas if it was running). It also creates a
local "Atlas Local" signing certificate, so the Keychain keeps trusting each new build. Log:
`~/Library/Logs/Atlas/updater.log`.

## Differences from Atlas 1.0.1 (Windows)

- No license gating (Lemon Squeezy), no Google Analytics, and no SMTP password inside the app.
- Apply and Fix Drift run the plan that was reviewed instead of `apply -auto-approve`.
- Security group rules that only reference other groups are left to Terraform instead of being widened to `0.0.0.0/0`.
- Extracted variables are declared in `atlas_env_variables.tf`, so your own `variables.tf` is left alone.
- Drift checks run while Atlas is open, as before; nothing runs in the background when it is closed.

Accounts are not migrated from the Windows version: DPAPI-protected secrets can only be decrypted on Windows.
Add them again on the Accounts page.
