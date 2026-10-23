# Atlas for macOS

Native macOS version of Atlas, written in **Swift + SwiftUI** (macOS 14+).
It replaces the original WPF/.NET version for Windows, which has been removed from this repository.

## Requirements

- macOS 14 Sonoma or later
- Swift 5.9+ (the Xcode Command Line Tools are enough; Xcode is optional)

## Build and run

```bash
cd Atlas
swift run                    # development
./scripts/build-app.sh       # creates dist/Atlas.app (release, ad-hoc signature)
./scripts/test.sh            # unit tests
./scripts/test-isolated.sh   # same tests in an isolated environment (sandbox, no network)
open dist/Atlas.app
```

To open it in Xcode: `open Package.swift`.
To distribute: `SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh`, then notarize.

## Architecture

```
Sources/Atlas/
├── App/        AtlasApp (entry point, menus, shortcuts), AppState (account/region/navigation)
├── AWS/        Own AWS client, no external dependencies:
│               SigV4 (CryptoKit), Query / JSON 1.1 / REST-JSON / S3 REST-XML, XML parser
├── Models/     Data structs (EC2, S3, IAM, CloudWatch, GuardDuty, costs…)
├── Services/   Ec2, S3, Iam/Sts, CloudWatch, Cost Explorer, GuardDuty, SecurityAudit, Search, Dashboard
├── Storage/    Keychain (secrets) + AccountStore (JSON in ~/Library/Application Support/Atlas)
└── Views/      SwiftUI: Dashboard, EC2, S3, IAM, CloudWatch, GuardDuty, Audit, Billing, Accounts, ⌘K search
```

| Windows (.NET)                    | macOS (Swift)                                  |
|-----------------------------------|------------------------------------------------|
| WPF + XAML + MVVM Toolkit         | SwiftUI (`ObservableObject`, `Table`, `Charts`) |
| AWS SDK for .NET                  | Own client with SigV4 (`AWS/`)                 |
| DPAPI + SQLite                    | macOS Keychain + JSON                          |
| Light/Dark theme (XAML)           | System appearance + manual choice (View › Appearance) |

## What was ported

- **Accounts**: add with STS validation, remove, switch active account, region selector
- **Dashboard**: EC2/S3/alarm KPIs, month-to-date cost, forecast, previous month, daily chart, top services
- **EC2**: list, search, status filter, multi-select, Start/Stop/Reboot/Terminate with confirmation,
  details panel (all fields), CloudWatch metrics, launch wizard, key pair creation, CSV export
- **S3**: buckets (with region), folder browsing, upload/download with progress, drag & drop,
  create folder, delete (including folders), create/delete bucket, text editor, CSV export
- **IAM**: users, roles, groups, policies; details panel; access key management; policy document
- **CloudWatch** (alarms), **GuardDuty** (findings), **Security Quick Audit**, **Billing** (Cost Explorer)
- **⌘K search** across EC2, S3 and IAM

Shortcuts: ⌘R refresh · ⌘K search · ⌘1…⌘9 pages.

## Not ported yet

- Terraform / Stacks (import, HCL generation, drift, env vars)
- SSM terminal (embedded session)
- IAM user/group creation and deletion wizards
- Licensing, auto-update (Velopack → Sparkle on macOS) and the contact form

Accounts are not migrated from the Windows version: DPAPI-protected secrets can only be decrypted on Windows.
Add them again on the Accounts page.
