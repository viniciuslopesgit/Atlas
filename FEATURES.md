
# Atlas — Features

> Desktop AWS management client built with WPF / .NET 9.

---

## Navigation & Shell

- Sidebar with radio-button nav items and a 3 px blue active indicator bar
- Pages: **Dashboard**, **EC2 Instances**, **S3 Buckets**, **Settings**
- Placeholder items (IAM, CloudWatch) shown as disabled — reserved for future releases
- Theme toggle button in the top bar (☀ / 🌙) switches between Dark and Light themes at runtime without restart
- Active AWS account picker in the top bar — switching accounts reloads all data automatically

---

## Dashboard

- KPI cards: **EC2 Running** (green), **EC2 Stopped** (red), **S3 Buckets** (blue), **Active CloudWatch Alarms** (red)
- Account ID display
- Last-refreshed timestamp (HH:mm:ss)
- Manual **Refresh** button
- "No account configured" empty state with guidance to open Settings
- Loading overlay while data is being fetched
- Error banner if any request fails
- Dashboard API calls run concurrently; one failed permission (e.g. no CloudWatch access) does not crash the rest
- Busca global de recursos (Global Search)
- Costs and usage overview (Cost Explorer integration)
---

## EC2 Instances

### List & Filtering

- Table columns: State badge, Name, Instance ID, Type, Public IP, Private IP, Launch Time
- Real-time **search** by name, instance ID, or IP address
- **Status filter** dropdown: All, running, stopped, pending, terminated
- Instance count shown in the header
- Color-coded state badges: green (running), red (stopped), amber (pending / stopping), purple (shutting-down), gray (terminated)
- Minimum column widths enforced — horizontal scroll appears instead of columns collapsing
- `Ctrl+A` hint in the action bar to select all visible rows

### Multi-Select & Batch Actions

- Individual row checkboxes + header select-all / deselect-all toggle
- Selection count pill
- **Start**, **Stop**, **Reboot**, **Terminate** buttons appear in a slide-in action bar at the bottom of the table
- All actions require a confirmation dialog before executing (see *Confirm Dialog* below)
- After an action completes the list auto-reloads to reflect the new state

### Instance Detail Panel

Slides in on the right side (360–460 px) whenever **exactly one** instance is selected. Disappears when the selection is cleared or multiple rows are selected.

#### Instance summary
| Field | Notes |
|---|---|
| Instance ID | With ⧉ copy button |
| Instance state | Color reflects current state |
| Instance type | |
| vCPUs | Derived from CpuOptions |
| Public / Private / IPv6 address | |
| Region | |
| Public DNS | |
| Private IP DNS name | |
| VPC ID | |
| Subnet ID | |
| IAM role | Name displayed, full ARN in tooltip |
| Auto Scaling Group | |
| IMDSv2 | optional / required |
| Owner | Account ID |
| Instance ARN | With ⧉ copy button |

#### Instance details
| Field | Notes |
|---|---|
| AMI ID | With ⧉ copy button |
| Monitoring | enabled / disabled |
| Platform details | Linux/UNIX, Windows, etc. |
| Key pair assigned at launch | |
| Launch time | |
| Virtualization type | hvm / paravirtual |
| Lifecycle | normal / spot / scheduled |
| Usage operation | |
| Credit specification | standard / unlimited |
| Boot mode | |
| Current instance boot mode | |
| AMI launch index | |
| State transition message | |

#### Host and placement group
Tenancy, Host ID, Affinity, Placement group, Placement group ID, Partition number, Reservation ID, Number of vCPUs

#### Capacity reservation
Capacity Reservation ID, Capacity Reservation setting

---

## S3 Buckets

- Bucket list panel (left, 280 px) with bucket name and creation date
- Object browser panel (right) — click a bucket to load its objects
- Object table columns: Key/Name, Size (auto-formatted as B / KB / MB / GB), Storage Class, Last Modified
- **Upload** — opens file picker, uploads with real-time progress bar and percentage
- **Download** — opens save dialog, downloads with real-time progress bar and percentage
- Prefix-based object navigation (folder-like browsing)
- Empty state illustration when no bucket is selected

---

## Account Management (Settings)

- Add AWS accounts: Name, Access Key ID, Secret Access Key (masked input), Default Region
- 12 supported regions in the dropdown (us-east-1, eu-west-1, ap-southeast-1, …)
- **Validate & Add Account** — calls STS `GetCallerIdentity` to verify credentials before saving
- Inline validation feedback (green success / red error message)
- Configured accounts list: shows name, access key ID, region, active badge
- **Set Active** button to switch the working account
- **Remove** button to delete an account (if it was active, the next account becomes active automatically)

---

## Confirm Dialog

Custom modal that matches the application theme — no native Windows chrome:

- Frameless window with `CornerRadius="14"` and a deep drop-shadow
- Draggable by the header area
- Icon circle + title + message text + monospace instance list
- Two visual kinds:
  - **Default** — blue `▶` icon and blue Confirm button (Start, Stop, Reboot)
  - **Danger** — red `⚠` icon and red Confirm button (Terminate)
- Terminate action message explicitly states the operation is permanent and cannot be undone
- **Cancel** / **Confirm** buttons; dialog is centered over the main window

---

## Themes

| Token | Dark | Light |
|---|---|---|
| Background | #0C0C0C | #F5F5F5 |
| Surface (cards) | #161616 | #FFFFFF |
| Border | #242424 | #E8E8E8 |
| Accent | #3B82F6 | #2563EB |
| Text primary | #EBEBEB | #191919 |
| Text secondary | #8A8A8A | #6B6B6B |
| Success | #4ADE80 | #16A34A |
| Warning | #FBBF24 | #D97706 |
| Danger | #F87171 | #DC2626 |

All controls (TextBox, ComboBox, DataGrid, ScrollBar, CheckBox, ProgressBar, Buttons) use fully custom templates that adapt to the active theme at runtime.

---

## Security

- AWS secret keys are encrypted with **Windows DPAPI** (user-scoped) before being written to the local SQLite database
- Keys are only decrypted in memory at the moment an AWS API call is made
- No plaintext credentials are persisted anywhere on disk

---

## Error Handling & Logging

- Unhandled UI, AppDomain, and Task exceptions are all caught at the application level
- Errors are written to `atlas-errors.txt` (in the application directory) in prepend mode — most recent entries appear first
- Log format: `[YYYY-MM-DD HH:mm:ss] [LEVEL] message` followed by the full exception stack trace
- Error banners displayed in the UI for recoverable errors (e.g. a failed AWS call) without crashing the application

---

## Performance

- AWS SDK clients are cached per `(service, region, access key)` tuple — underlying HTTP connections are reused
- Cache is fully invalidated when the active account changes
- Dashboard API calls run in parallel (`Task.WhenAll`)
- Each ViewModel caches loaded data for **30 seconds** — navigating back to a page within that window uses the cached result instead of making a new API call
- Previous in-flight load is cancelled (`CancellationToken`) when a new load is triggered

---

## Technology Stack

| Layer | Technology |
|---|---|
| Runtime | .NET 9.0 (Windows) |
| UI framework | WPF (XAML) |
| MVVM | CommunityToolkit.Mvvm |
| AWS SDK | AWSSDK.EC2, S3, CloudWatch, SecurityToken |
| Local database | SQLite via Microsoft.Data.Sqlite |
| Dependency injection | Microsoft.Extensions.Hosting |
| Credential security | Windows DPAPI |



- Multi-account management com troca rápida no topo