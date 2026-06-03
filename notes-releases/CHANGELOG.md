# Changelog

All notable changes to Atlas will be documented in this file.

---

## [0.0.1] — 2026-06-02

### Initial release

First public build of **Atlas** — a desktop AWS management client for Windows built on WPF / .NET 9.

---

### Added

#### Shell & Navigation
- Sidebar navigation with radio-button items and a 3 px blue active indicator
- Pages: Dashboard, EC2 Instances, S3 Buckets, IAM, Billing, CloudWatch, GuardDuty, Settings
- PRO gating: IAM, Billing, CloudWatch, and GuardDuty are locked behind an upgrade prompt on free tier
- Theme toggle (☀ / 🌙) in the top bar — switches between Dark and Light themes at runtime without restart
- Active account picker in the top bar — switching accounts reloads all page data automatically
- Global resource search bar

#### Dashboard
- KPI cards: EC2 Running, EC2 Stopped, S3 Buckets, Active CloudWatch Alarms
- Account ID display and last-refreshed timestamp
- Manual Refresh button
- "No account configured" empty state with guidance to open Settings
- Loading overlay and error banner
- Dashboard API calls execute concurrently — a single failed permission does not block the rest
- Cost Explorer integration: costs and usage overview panel

#### EC2 Instances
- Table with columns: State badge, Name, Instance ID, Type, Public IP, Private IP, Launch Time
- Real-time search by name, instance ID, or IP address
- Status filter dropdown: All / running / stopped / pending / terminated
- Color-coded state badges (green, red, amber, purple, gray)
- Multi-select via row checkboxes plus header select-all toggle
- Batch actions: Start, Stop, Reboot, Terminate — all require a confirmation dialog
- Auto-reload after any batch action completes
- Instance detail side panel (slides in when exactly one row is selected):
  - Summary: ID, state, type, vCPUs, IPs, region, DNS, VPC/Subnet, IAM role, ASG, IMDSv2, ARN
  - Details: AMI ID, monitoring, platform, key pair, launch time, virtualization, lifecycle, boot mode, credit spec
  - Host & placement: tenancy, host ID, affinity, placement group, partition, reservation
  - Capacity reservation fields
- Ctrl+A shortcut hint in the action bar
- Minimum column widths with horizontal scroll instead of column collapse

#### S3 Buckets
- Bucket list panel (left) with name and creation date
- Object browser panel (right) — click a bucket to load its contents
- Object table columns: Key/Name, Size (auto-formatted B / KB / MB / GB), Storage Class, Last Modified
- Upload with real-time progress bar and percentage
- Download with save dialog and real-time progress bar and percentage
- Prefix-based folder-like navigation
- Empty state illustration when no bucket is selected

#### IAM *(PRO)*
- Accessible to PRO accounts

#### Billing *(PRO)*
- Accessible to PRO accounts

#### CloudWatch *(PRO)*
- Alarms list with state filter chips: All / ALARM / OK / INSUFFICIENT_DATA
- Real-time text search across alarms
- KPI cards per alarm state

#### GuardDuty *(PRO)*
- Findings list with severity filter chips: All / HIGH / MEDIUM / LOW
- Real-time text search across findings
- KPI cards per severity level

#### Account Management (Settings)
- Add AWS accounts: Name, Access Key ID, Secret Access Key (masked), Default Region
- 12 supported regions in the dropdown
- Validate & Add Account — verifies credentials via STS `GetCallerIdentity` before saving
- Inline validation feedback (green / red)
- Account list with name, access key ID, region, and active badge
- Set Active and Remove buttons; next account activates automatically when the active one is removed

#### Confirm Dialog
- Frameless modal matching application theme (no native Windows chrome)
- Draggable header, rounded corners, deep drop-shadow
- Default variant (blue icon + button) for Start / Stop / Reboot
- Danger variant (red icon + button) for Terminate, with explicit irreversibility warning
- Centered over the main window

#### Themes
- Full Dark and Light theme support via `ResourceDictionary` swap at runtime
- Custom templates for all controls: TextBox, ComboBox, DataGrid, ScrollBar, CheckBox, ProgressBar, Buttons
- Design tokens: background, surface, border, accent, text primary/secondary, success, warning, danger

#### Security
- AWS secret keys encrypted with Windows DPAPI (user-scoped) before writing to SQLite
- Keys decrypted in memory only at the moment an AWS API call is made
- No plaintext credentials persisted on disk

#### Error Handling & Logging
- Unhandled UI, AppDomain, and Task exceptions caught at application level
- Errors written to `atlas-errors.txt` (application directory) in prepend mode — newest entries first
- Log format: `[YYYY-MM-DD HH:mm:ss] [LEVEL] message` + full stack trace
- Recoverable errors show an error banner in the UI without crashing

#### Performance
- AWS SDK clients cached per `(service, region, access key)` — HTTP connections reused
- Cache fully invalidated on account switch
- Dashboard API calls run in parallel via `Task.WhenAll`
- Each ViewModel caches loaded data for 30 seconds — navigating back within that window skips a new API call
- In-flight loads cancelled via `CancellationToken` when a new load is triggered

#### Technology Stack
- Runtime: .NET 9.0 (Windows, x64)
- UI: WPF (XAML) + CommunityToolkit.Mvvm
- AWS SDK v3: EC2, S3, CloudWatch, CostExplorer, SecurityToken, GuardDuty
- Local database: SQLite via Microsoft.Data.Sqlite
- DI: Microsoft.Extensions.Hosting
- Credential security: Windows DPAPI

---

[0.0.1]: https://github.com/your-org/atlas/releases/tag/v0.0.1
