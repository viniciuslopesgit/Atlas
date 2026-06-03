# Atlas

Desktop AWS management tool for Windows, built with C# · .NET 9 · WPF · MVVM.

---

## Prerequisites

| Tool | Version | Link |
|------|---------|------|
| .NET SDK | **9.0** | https://dotnet.microsoft.com/download/dotnet/9.0 |
| Visual Studio | 2022 17.8+ | (optional, but recommended) |

> The project targets `net9.0-windows` and requires an **x64** machine.

---

## Quick Start

```powershell
# 1. Clone / open the folder
cd "C:\Users\conta\Documents\vinicius\Atlas"

# 2. Restore packages
dotnet restore Atlas/Atlas.csproj

# 3. Build
dotnet build Atlas/Atlas.csproj -c Release

# 4. Run
dotnet run --project Atlas/Atlas.csproj
```

Or open `Atlas/Atlas.csproj` directly in **Visual Studio 2022** and press **F5**.

---

## First Run

1. The app opens to the **Dashboard** (empty until an account is configured).
2. Click **Settings** in the sidebar.
3. Fill in:
   - Account Name (any label, e.g. "Production")
   - Access Key ID
   - Secret Access Key
   - Default Region
4. Click **Validate & Add Account** — credentials are verified via STS `GetCallerIdentity` before saving.
5. Navigate back to **Dashboard** and click **Refresh**.

---

## Project Structure

```
Atlas/
├── Models/                 Plain data objects (AwsAccount, Ec2InstanceModel, …)
├── ViewModels/             MVVM ViewModels (CommunityToolkit.Mvvm)
│   ├── MainViewModel.cs    Navigation + top-bar state
│   ├── DashboardViewModel.cs
│   ├── Ec2ViewModel.cs
│   ├── S3ViewModel.cs
│   └── SettingsViewModel.cs
├── Views/                  WPF UserControls (one per page)
├── Services/
│   ├── IAccountService / AccountService.cs   Credential management
│   ├── IThemeService   / ThemeService.cs     Dark / Light toggle
│   ├── IAwsSessionFactory                    Centralised AWS credential resolution
│   └── AWS/
│       ├── IEc2Service   / Ec2Service.cs
│       ├── IS3Service    / S3Service.cs
│       └── IDashboardService / DashboardService.cs
├── Infrastructure/
│   ├── Security/   DpapiCredentialProtector  (Windows DPAPI encryption)
│   └── Database/   DatabaseContext + AccountRepository (SQLite)
├── Themes/
│   ├── DarkTheme.xaml
│   ├── LightTheme.xaml
│   └── ControlStyles.xaml  (all global control styles)
├── Helpers/
│   ├── Converters.cs       (Bool/Null/Zero → Visibility, BoolInvert)
│   └── PageCheckConverter.cs
├── App.xaml / App.xaml.cs  DI container setup (Microsoft.Extensions.Hosting)
└── MainWindow.xaml         Shell: top-bar + sidebar + ContentPresenter
```

---

## Architecture

```
┌──────────┐   binds    ┌─────────────┐   calls   ┌──────────────────┐
│  View    │ ─────────► │  ViewModel  │ ─────────► │  Service (AWS)   │
│  (XAML)  │            │ (ObservableObject)       │  SDK v3          │
└──────────┘            └─────────────┘            └──────────────────┘
                                │                         │
                                │                   ┌─────▼───────────┐
                                │                   │  AwsSessionFactory│
                                │                   │  (credentials)  │
                                │                   └─────────────────┘
                        ┌───────▼──────┐
                        │ AccountService│ ← ICredentialProtector (DPAPI)
                        │  SQLite DB   │
                        └──────────────┘
```

- **DI container**: `Microsoft.Extensions.Hosting` — configured in `App.xaml.cs`
- **ViewModels**: `CommunityToolkit.Mvvm` `[ObservableProperty]` + `[RelayCommand]`
- **Theme switching**: `ResourceDictionary` swap at runtime; brushes are `DynamicResource`
- **Credential storage**: Windows DPAPI (`ProtectedData.Protect`) — bound to the current Windows user account; no external key management needed

---

## NuGet Packages

| Package | Purpose |
|---------|---------|
| `AWSSDK.EC2` / `S3` / `CloudWatch` / `CostExplorer` / `SecurityToken` | AWS SDK v3 |
| `Microsoft.Extensions.Hosting` | DI + lifetime management |
| `CommunityToolkit.Mvvm` | Source-generated MVVM boilerplate |
| `Microsoft.Data.Sqlite` | Local database (credentials + settings cache) |

---

## Extending

### Add a new AWS module (e.g. RDS)

1. Create `Models/RdsInstanceModel.cs`
2. Create `Services/AWS/IRdsService.cs` + `RdsService.cs`
3. Register in `App.xaml.cs`: `services.AddTransient<IRdsService, RdsService>()`
4. Create `ViewModels/RdsViewModel.cs` (inject `IRdsService`)
5. Create `Views/RdsView.xaml` + `.xaml.cs`
6. Add enum value to `NavigationPage` and a nav item in `MainWindow.xaml`
7. Add `DataTemplate` in `MainWindow.xaml` Resources

### Toggle theme from code

```csharp
var themeService = app.Services.GetRequiredService<IThemeService>();
themeService.Apply(AppTheme.Light);
```
