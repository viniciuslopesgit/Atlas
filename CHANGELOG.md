# Changelog

Notable changes in each version of Atlas. Format [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versions [SemVer](https://semver.org/).
Each version is first published as a beta and becomes stable when it meets the [release criteria](docs/RELEASE_CRITERIA.md).
Versions up to 1.0.1 are the Windows app.

## [2.7.0] - 2026-10-23

Atlas 2.7.0 makes stacks start faster and pages open instantly. A stack's container is now checked with a single
call before each run instead of three, and the Terraform and OpenTofu providers are downloaded once and shared by
every stack of the same engine, so Init in a new stack no longer downloads the AWS provider again. Pages keep what
they loaded from AWS for each account and region: going back to EC2, S3, IAM, CloudWatch, GuardDuty, Billing or
the Dashboard shows it at once and loads it again after 3 minutes, after a change made on the page, or with Refresh
(⌘R). Infrastructure as Code is now its own menu in the sidebar, below Stacks, and Import from AWS lives there: it
adds the resources to the open project or to a stack. A stack's runs open as a timeline of their phases.

### Added
- Import from AWS, in Infrastructure as Code, can add the resources to a stack: the stack imports them in its
  container (state in S3, generated configuration, variables in the Keychain) and Stacks opens on it
- A stack's runs, plans and applies each have their tab; a run opens as a timeline of its phases (preparing, init,
  plan, apply, verify) with date, time and duration, and output that can be collapsed, enlarged or downloaded;
  every finished run keeps its whole log, encrypted

### Changed
- Stacks: the providers are downloaded once per engine and shared by all stacks (Terraform checks them against
  each stack's lock file); existing containers are recreated once to use the shared cache
- Stacks: a run in a container that is already running starts right away, without asking Docker whether it is up
  and starting the container again
- Pages show what they loaded from AWS at once when you come back to them, and refresh it after 3 minutes, after a
  change, or with Refresh (⌘R)
- Infrastructure as Code moved out of Resources to its own menu in the sidebar, below Stacks
- Import from AWS moved from each stack to Infrastructure as Code
- A run's output is shown in its timeline (Runs, Plans, Applies) instead of a bar at the bottom of the stack

### Security
- New stacks keep their Terraform state in S3 by default (atlas-tfstate-<account>, versioned, encrypted, private),
  each in its own object, instead of a plain-text terraform.tfstate in the stack's folder; a folder that already has
  a backend or a local state is left as it is
- A stack whose state is a local terraform.tfstate shows a warning and a "Local state" badge; Move State to S3 copies
  it to the state bucket, reads it back from there, and only then removes terraform.tfstate and its backup
- Plan files (which hold the configuration and variable values in plain text) are saved in Atlas's private folder,
  readable only by you, instead of the stack's or project's folder; plan files left there by earlier versions are removed
- The AWS secret key, session token and stack variable values are masked in all Terraform/OpenTofu output: on screen,
  in saved run logs, in drift reports and in error messages
- stacks.json and terraform-projects.json are readable only by you, and a stack's drift summary and diff are encrypted
  like its run logs
- Terraform's debug logs (TF_LOG, TF_LOG_PATH) are never turned on from the environment Atlas was started with
- A copied secret access key is marked concealed, so clipboard managers and Universal Clipboard leave it out, and is
  cleared after 60 seconds unless you copied something else
- A downloaded run log is readable only by you, and errors in the system log no longer show AWS error details

### Fixed
- Stacks with many variables or runs no longer slow the app down: saving a stack only writes to the Keychain and
  disk what changed, and Keychain credentials are read once per account instead of on every screen update
- Stacks with EKS clusters plan and apply in their container: 'aws eks get-token', used by the kubernetes and helm
  providers, now works there with the stack's Atlas account, without the AWS CLI
- Stack Init works with Docker Desktop opened from Finder (the image pull finds Docker's credential helper), and
  each stack's container keeps its own Terraform/OpenTofu data folder, so a .terraform made on the Mac no longer
  breaks init with "Backend configuration changed"

## [2.6.0] - 2026-10-23

Atlas 2.6.0 lets you change an S3 bucket's settings and keeps a closer watch on GuardDuty. S3 › Settings shows
and edits a bucket's versioning, default encryption, Block Public Access, tags, lifecycle rules and policy; each
change is described and confirmed before it reaches AWS. While Atlas is open it checks GuardDuty in the active
account and region every 2 minutes and posts a desktop notification for each new finding, or a summary when
there are several. The GuardDuty page uses AWS's four severity levels, filters by severity, type and resource,
shows each finding's resource, action, actor, count and first and last seen, and archives and unarchives findings.

### Added
- S3 › Settings (also in a bucket's context menu): versioning, default encryption (SSE-S3, SSE-KMS, DSSE-KMS),
  Block Public Access, tags, lifecycle rules and bucket policy, each saved only after you confirm the change
- Lifecycle rules Atlas can't edit (tag or size filters, dates…) are kept exactly as they are when you save
- GuardDuty desktop notifications for new findings in the active account and region, checked every 2 minutes;
  what was already announced is remembered, so nothing repeats after a restart. Turn them off in Accounts › Notifications
- GuardDuty: filter by severity, finding type and resource type; archive and unarchive findings; see archived findings

### Changed
- GuardDuty severities follow AWS: Low 1.0–3.9, Medium 4.0–6.9, High 7.0–8.9 and Critical 9.0–10.0
- A GuardDuty finding shows its resource (instance, access key, bucket, cluster…), its action (API call,
  connection, port probe, DNS request…), the actor (remote IP, location, organization, threat list), count and
  first and last seen
- The GuardDuty page says when GuardDuty is not enabled, or is suspended, in the region

## [2.5.1] - 2026-10-23

Atlas 2.5.1 brings 1 fix.

### Fixed
- Long Stacks runs keep only their last 1 MB of output and redraw at most 10 times a second; a failed or oversized Docker Desktop install leaves nothing behind

## [2.5.0] - 2026-10-23

Atlas 2.5.0 runs each Stack in its own isolated container. When Docker Desktop, OrbStack, Colima or Apple's
`container` is on the Mac, creating a stack creates a container dedicated to it, and Init, Plan, Apply, drift
checks and Import from AWS run inside it with the official Terraform or OpenTofu image, so neither has to be
installed. On first launch without Docker, Atlas offers to install Docker Desktop; without a container runtime,
stacks keep running with the terraform on the Mac. Atlas is now installed from a .dmg.

### Added
- Each new stack gets its own container (stack folder mounted, read-only system, no capabilities, your user);
  plan, apply, drift checks and imports run inside it
- Stacks choose Terraform or OpenTofu, when created and later in Settings
- Atlas finds Docker Desktop, OrbStack, Colima or Apple's container on its own; with one there is nothing to do
- On first launch without Docker, Atlas offers to install Docker Desktop: it downloads it from docker.com, checks
  that it is signed by Docker Inc and copies it to Applications (also from Stacks › Settings)
- Atlas-X.Y.Z.dmg installer: open it and drag Atlas to Applications

### Changed
- AWS credentials and stack variables reach the container through its standard input for each run: never in a
  file, an image or a command line
- Removing a stack also removes its container
- Releases offer the .dmg instead of the .zip; the .zip stays only for the automatic updater
- Sheet, inspector and panel titles follow the minimal design (no bold or expanded type); account rows, the EC2
  selection count and the S3 drop target lose their boxes and pills
- Large S3 uploads and downloads update their progress at most once per percent, keeping the window responsive
- The Accounts page no longer reads the updater's state on every redraw

### Fixed
- Signed AWS requests only go to HTTPS AWS endpoints: a region or bucket name can no longer send them to another host
- AWS responses are never cached on disk and AWS calls never use cookies
- A new key pair's .pem is never readable by other users, not even while it is being written
- accounts.json is readable only by you (0600, its folder 0700)
- Error pages that do not come from AWS (a proxy, a captive portal) are cut to their first lines

## [2.4.1] - 2026-10-23

Atlas 2.4.1 corrects the wording of the text in the app, on the website and in the documentation.

### Fixed
- Clearer, consistent wording in the security audit, EC2 details, Launch Instance and IaC tooltips
  ("Availability Zone", "managed node ID", "None (proceed without a key pair)")
- Broken symbols in the website's Dashboard and EC2 documentation, and grammar on the site, README and guides

## [2.4.0] - 2026-10-23

Atlas 2.4.0 brings 1 new feature.

### Added
- EC2 › Connect works without the Session Manager plugin — Atlas speaks the protocol itself

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

[2.7.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.7.0
[2.6.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.6.0
[2.5.1]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.5.1
[2.5.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.5.0
[2.4.1]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.4.1
[2.4.0]: https://github.com/viniciuslopesgit/Atlas/releases/tag/2.4.0
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
