# Changelog

Notable changes in each version of Atlas. Format [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions [SemVer](https://semver.org/).
Each version is first published as a beta and becomes stable when it meets the [release criteria](docs/RELEASE_CRITERIA.md).
Versions up to 1.0.1 are the Windows app.

## [2.3.0] - 2026-10-23

Atlas 2.3.0 brings 1 new feature.

### Added
- Sidebar with three fixed menus — Dashboard, Resources and Stacks; Resources opens its pages in a submenu to the right

## [2.2.0] - 2026-10-23

Atlas 2.2.0 brings 1 new feature.

### Added
- Sidebar shows Stacks under Dashboard, Billing among the resources and only the IaC header

## [2.1.0] - 2026-10-23

Atlas 2.1.0 brings 1 new feature.

### Added
- Minimal design — no card boxes or icon tiles, light figures, grey charts, text-only sidebar

## [2.0.0] - 2026-10-23

Atlas is now a native macOS app, written in Swift and SwiftUI, for macOS 14 or later on Apple silicon and Intel. It replaces the Windows app: settings and accounts from 1.x are not carried over. Everything it does with AWS goes through its own client, with no AWS CLI and no other dependencies, and secret keys stay in the macOS Keychain.

### Added
- Dashboard with the month-to-date cost, the forecast and the cost by service.
- EC2: list instances, start, stop, reboot and terminate several at once, see details and metrics, and launch new instances with a wizard.
- EC2: Connect opens an SSM shell to an instance in Terminal, through the Session Manager plugin.
- S3: browse buckets and folders, upload and download with progress, drag and drop files, and edit text objects.
- IAM: users, roles, groups and policies; create users with console access, groups, policies, tags and an access key; delete them with their dependencies; attach and detach policies; activate, deactivate, create and delete access keys.
- CloudWatch alarms, GuardDuty findings and a security audit: root MFA, password policy, old access keys, IMDSv1 and S3 public access.
- Billing by month and by service.
- Infrastructure as Code: Terraform projects with init, validate, plan, apply and output, and import of existing AWS resources (34 types) into Terraform.
- Stacks: Terraform stacks with run history, environment variables kept in the Keychain, scheduled drift checks and optional automatic fixes.
- Search across resources and pages with ⌘K; several AWS accounts.
- Feedback page that opens Mail or copies a GitHub issue, with no password inside the app.
- Automatic updates of the installed app (Atlas/scripts/install-updater.sh), which check the download against SHA256SUMS.

### Removed
- The Windows app, the Lemon Squeezy license, Google Analytics and the feedback e-mail password that 1.0.1 shipped inside the app.

## [1.0.1] - 2026-06-13

### Changed
- Terraform Import está a funcionar
- IaS

## [1.0.0] - 2026-06-12

### Changed
- IaS
- IaS

## [0.0.31] - 2026-06-05

### Changed
- Fix - Windows Firewall bloqueava conexões de saída do Atlas.exe com SocketException 10013 (WSAEACCES)Firewall

## [0.0.30] - 2026-06-05

### Changed
- Fix - Windows Firewall bloqueava conexões de saída do Atlas.exe com SocketException 10013 (WSAEACCES)Firewall

## [0.0.29] - 2026-06-04

### Changed
- Fix - Windows Firewall bloqueava conexões de saída do Atlas.exe com SocketException 10013 (WSAEACCES)Firewall

## [0.0.28] - 2026-06-04

### Changed
- Fix - Windows Firewall bloqueava conexões de saída do Atlas.exe com SocketException 10013 (WSAEACCES)Firewall
- Fix download links to use correct MSI filename (Atlas-win.msi)

## [0.0.27] - 2026-06-04

### Changed
- Fix - Windows Firewall bloqueava conexões de saída do Atlas.exe com SocketException 10013 (WSAEACCES)Firewall
- Fix - Windows Firewall bloqueava conexões de saída do Atlas.exe com SocketException 10013 (WSAEACCES)Firewall
- Windows Firewall bloqueava conexões de saída do Atlas.exe com SocketException 10013 (WSAEACCES)Firewall

## [0.0.26] - 2026-06-04

### Changed
- Windows Firewall bloqueava conexões de saída do Atlas.exe com SocketException 10013 (WSAEACCES)Firewall

## [0.0.25] - 2026-06-04

### Changed
- Google Analytics

## [0.0.24] - 2026-06-04

### Changed
- Google Analytics

## [0.0.23] - 2026-06-04

### Changed
- Google Analytics
- Google Analytics
- Google Analytics

## [0.0.22] - 2026-06-04

### Changed
- Google Analytics
- Update AnalyticsService.cs
- Add Google Analytics via GA4 Measurement Protocol

## [0.0.21] - 2026-06-04

### Changed
- Google Analytics

## [0.0.20] - 2026-06-03

### Changed
- Download button link URL

## [0.0.19] - 2026-06-03

### Changed
- Download button link URL

## [0.0.17] - 2026-06-03

### Changed
- Add workflow website push

## [0.0.16] - 2026-06-03

### Fixed
- SignPath artifact-configuration slug e action v2 (`8f48b04`)

## [0.0.15] - 2026-06-03

_No changes._

## [0.0.14] - 2026-06-03

### Changed
- Add workflow permissions for SignPath artifact access

## [0.0.13] - 2026-06-03

### Changed
- Fix SignPath action parameters

## [0.0.12] - 2026-06-03

### Changed
- Fix nuget.config for CI environment

## [0.0.11] - 2026-06-03

### Changed
- Fix vpk install source in workflow

## [0.0.10] - 2026-06-03

_No changes._

## [0.0.9] - 2026-06-03

### Changed
- Initial commit + release workflow with SignPath

## [0.0.8] - 2026-06-03

### Changed
- Add release workflow with SignPath signing + bump to 0.0.8
- Delete atlas_v1.0.0.exe
- 0.0.1

[2.3.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.3.0
[2.2.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.2.0
[2.1.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.1.0
[2.0.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.0.0
[1.0.1]: https://github.com/viniciuslopesgit/Atlas/releases/tag/1.0.1
[1.0.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/1.0.0
[0.0.31]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.31
[0.0.30]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.30
[0.0.29]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.29
[0.0.28]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.28
[0.0.27]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.27
[0.0.26]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.26
[0.0.25]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.25
[0.0.24]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.24
[0.0.23]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.23
[0.0.22]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.22
[0.0.21]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.21
[0.0.20]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.20
[0.0.19]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.19
[0.0.17]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.17
[0.0.16]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.16
[0.0.15]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.15
[0.0.14]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.14
[0.0.13]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.13
[0.0.12]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.12
[0.0.11]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.11
[0.0.10]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.10
[0.0.9]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.9
[0.0.8]: https://github.com/viniciuslopesgit/Atlas/releases/tag/0.0.8
