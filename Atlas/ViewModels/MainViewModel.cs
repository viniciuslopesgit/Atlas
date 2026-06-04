using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using Atlas.Services;
using System.Collections.ObjectModel;
using System.Collections.Generic;
using System.Threading.Tasks;
using System.Reflection;

namespace Atlas.ViewModels;

public enum NavigationPage { Dashboard, EC2, S3, IAM, Billing, CloudWatch, GuardDuty, Settings, Contact }

public partial class MainViewModel : ObservableObject
{
    private readonly IThemeService _theme;
    private readonly IAccountService _accounts;
    private readonly ILicenseService _license;
    private readonly IUpgradeService _upgrade;
    private readonly IUpdateService _updates;
    private readonly IAnalyticsService _analytics;

    public DashboardViewModel    DashboardVM    { get; }
    public Ec2ViewModel         Ec2VM          { get; }
    public S3ViewModel          S3VM           { get; }
    public IamViewModel         IamVM          { get; }
    public BillingViewModel     BillingVM      { get; }
    public CloudWatchViewModel  CloudWatchVM   { get; }
    public GuardDutyViewModel   GuardDutyVM    { get; }
    public SettingsViewModel    SettingsVM     { get; }
    public ContactViewModel     ContactVM      { get; }

    /// <summary>License activation card shown inside the in-window upgrade overlay.</summary>
    public LicenseViewModel License { get; }

    /// <summary>Command palette accessed via Ctrl+K.</summary>
    public CommandPaletteViewModel Palette { get; }

    /// <summary>True when a valid Pro license is active; false = Free tier.</summary>
    [ObservableProperty] private bool _isPro;

    /// <summary>Controls the in-window "Upgrade to Pro" overlay (dismissable — Free users can keep working).</summary>
    [ObservableProperty] private bool _isUpgradeOpen;

    /// <summary>Contextual line describing which Pro feature prompted the overlay.</summary>
    [ObservableProperty] private string? _upgradeReason;

    /// <summary>True when a newer version was found and is ready to download/apply.</summary>
    [ObservableProperty] private bool _isUpdateAvailable;

    /// <summary>Label shown on the update button, e.g. "v1.2.0 disponível".</summary>
    [ObservableProperty] private string _updateVersionDisplay = string.Empty;

    /// <summary>Convenience inverse of <see cref="IsPro"/> for badge/CTA visibility.</summary>
    public bool IsFree => !IsPro;

    partial void OnIsProChanged(bool value) => OnPropertyChanged(nameof(IsFree));

    /// <summary>Current application version, e.g. "v0.0.23 beta".</summary>
    public static string AppVersion { get; } =
        $"v{Assembly.GetEntryAssembly()?.GetName().Version?.ToString(3) ?? "0.0.23"} beta";

    /// <summary>Pages locked behind the Pro tier.</summary>
    private static bool IsProOnly(NavigationPage page) =>
        page is NavigationPage.IAM or NavigationPage.Billing or NavigationPage.CloudWatch or NavigationPage.GuardDuty;

    private static string PageDisplayName(NavigationPage page) => page switch
    {
        NavigationPage.EC2 => "EC2",
        NavigationPage.S3  => "S3",
        NavigationPage.IAM => "IAM",
        _                  => page.ToString()
    };

    [ObservableProperty] private NavigationPage _currentPage = NavigationPage.Dashboard;
    [ObservableProperty] private ObservableObject? _currentViewModel;
    [ObservableProperty] private string _themeIcon = char.ConvertFromUtf32(0xE706);
    [ObservableProperty] private AwsAccount? _selectedAccount;
    [ObservableProperty] private bool _isAccountMenuOpen;
    [ObservableProperty] private bool _isRegionMenuOpen;
    [ObservableProperty] private string _activeRegionDisplay = string.Empty;
    [ObservableProperty] private string _activeRegionCode = string.Empty;

    private bool _suppressAccountCallback;

    public sealed record RegionItem(string Code, string Display);

    public static readonly IReadOnlyList<RegionItem> AllRegions =
    [
        new("us-east-1",      "US East (N. Virginia)"),
        new("us-east-2",      "US East (Ohio)"),
        new("us-west-1",      "US West (N. California)"),
        new("us-west-2",      "US West (Oregon)"),
        new("ca-central-1",   "Canada (Central)"),
        new("eu-west-1",      "Europe (Ireland)"),
        new("eu-west-2",      "Europe (London)"),
        new("eu-west-3",      "Europe (Paris)"),
        new("eu-central-1",   "Europe (Frankfurt)"),
        new("eu-north-1",     "Europe (Stockholm)"),
        new("ap-southeast-1", "Asia Pacific (Singapore)"),
        new("ap-southeast-2", "Asia Pacific (Sydney)"),
        new("ap-northeast-1", "Asia Pacific (Tokyo)"),
        new("ap-northeast-2", "Asia Pacific (Seoul)"),
        new("ap-south-1",     "Asia Pacific (Mumbai)"),
        new("sa-east-1",      "South America (São Paulo)"),
    ];

    private static string RegionDisplayName(string code) =>
        AllRegions.FirstOrDefault(r => r.Code == code)?.Display ?? code;

    // Segoe MDL2 Assets glyphs
    private static readonly string IconSun  = char.ConvertFromUtf32(0xE706); // Brightness/Sun
    private static readonly string IconMoon = char.ConvertFromUtf32(0xE708); // Moon/Night

    public ObservableCollection<AwsAccount> Accounts { get; } = [];

    public string ActiveAccountName    => _accounts.ActiveAccount?.Name ?? "No account";
    public string ActiveAccountRegion  => _accounts.ActiveAccount?.DefaultRegion ?? string.Empty;
    public string ActiveAccountInitials => GetInitials(_accounts.ActiveAccount?.Name);
    public bool   HasActiveAccount      => _accounts.ActiveAccount != null;

    public MainViewModel(
        IThemeService theme,
        IAccountService accountService,
        ILicenseService licenseService,
        IUpgradeService upgradeService,
        IUpdateService updateService,
        IAnalyticsService analyticsService,
        LicenseViewModel licenseVM,
        CommandPaletteViewModel paletteVM,
        DashboardViewModel dashboardVM,
        Ec2ViewModel ec2VM,
        S3ViewModel s3VM,
        IamViewModel iamVM,
        BillingViewModel billingVM,
        CloudWatchViewModel cloudWatchVM,
        GuardDutyViewModel guardDutyVM,
        SettingsViewModel settingsVM,
        ContactViewModel contactVM)
    {
        _theme = theme;
        _accounts = accountService;
        _license = licenseService;
        _upgrade = upgradeService;
        _updates = updateService;
        _analytics = analyticsService;

        License = licenseVM;
        Palette = paletteVM;
        DashboardVM = dashboardVM;
        Ec2VM = ec2VM;
        S3VM = s3VM;
        IamVM = iamVM;
        BillingVM = billingVM;
        CloudWatchVM = cloudWatchVM;
        GuardDutyVM  = guardDutyVM;
        SettingsVM   = settingsVM;
        ContactVM    = contactVM;

        // Free by default — the app is fully usable without a key. Pro unlocks gated features.
        _isPro = _license.IsPro;

        // A locked Pro feature was requested somewhere in the app → surface the overlay.
        _upgrade.UpgradeRequested += (_, reason) => ShowUpgrade(reason);

        // Activation / revocation may flip the entitlement at runtime.
        _license.ProStatusChanged += (_, _) => IsPro = _license.IsPro;
        License.ActivationSucceeded += (_, _) =>
        {
            IsPro = _license.IsPro;
            IsUpgradeOpen = false;
        };

        _theme.ThemeChanged += (_, t) => ThemeIcon = t == AppTheme.Dark ? IconSun : IconMoon;
        _accounts.ActiveAccountChanged += (_, _) => RefreshAccounts();
        _accounts.ActiveRegionChanged += (_, _) => RefreshRegion();

        RefreshAccounts();
        RefreshRegion();
        NavigateTo(NavigationPage.Dashboard);
        InitializePaletteCommands();

        DashboardVM.NavigateToResultRequested = OnSearchResultNavigated;

        _ = CheckForUpdatesAsync();
    }

    private async Task CheckForUpdatesAsync()
    {
        // Aguarda a janela abrir para não atrasar o startup
        await Task.Delay(TimeSpan.FromSeconds(5));
        Atlas.Infrastructure.Logging.FileLogger.Info("[Update] Checking for updates...");
        var available = await _updates.CheckAsync();
        Atlas.Infrastructure.Logging.FileLogger.Info($"[Update] available={available}, version={_updates.AvailableVersion}");
        if (!available) return;
        UpdateVersionDisplay = $"v{_updates.AvailableVersion} disponível";
        IsUpdateAvailable = true;
    }

    [RelayCommand]
    private async Task ApplyUpdate()
    {
        IsUpdateAvailable = false; // esconde o botão imediatamente
        await _updates.ApplyAndRestartAsync();
    }

    private void OnSearchResultNavigated(SearchResult result)
    {
        switch (result.ResourceType)
        {
            case SearchResultType.EC2Instance:
                Ec2VM.FilterText = result.Name;
                NavigateTo(NavigationPage.EC2);
                break;
            case SearchResultType.S3Bucket:
                S3VM.BucketFilterText = result.Name;
                NavigateTo(NavigationPage.S3);
                break;
        }
    }

    [RelayCommand]
    private void OpenCommandPalette() => Palette.Open();

    [RelayCommand]
    private void ToggleTheme() => _theme.Toggle();

    /// <summary>Opens the upgrade overlay with an optional contextual reason.</summary>
    [RelayCommand]
    private void ShowUpgrade(string? reason = null)
    {
        UpgradeReason = string.IsNullOrWhiteSpace(reason)
            ? "Unlock multiple accounts, bulk actions, IAM and more with Atlas Pro."
            : reason;
        IsUpgradeOpen = true;
    }

    [RelayCommand]
    private void CloseUpgrade() => IsUpgradeOpen = false;

    [RelayCommand]
    private void ToggleAccountMenu()
    {
        IsAccountMenuOpen = !IsAccountMenuOpen;
        if (IsAccountMenuOpen) IsRegionMenuOpen = false;
    }

    [RelayCommand]
    private void ToggleRegionMenu()
    {
        IsRegionMenuOpen = !IsRegionMenuOpen;
        if (IsRegionMenuOpen) IsAccountMenuOpen = false;
    }

    [RelayCommand]
    private void SelectRegion(string code)
    {
        _accounts.SetActiveRegion(code);
        IsRegionMenuOpen = false;
        ReloadCurrentView();
    }

    private void ReloadCurrentView()
    {
        if      (CurrentViewModel is DashboardViewModel dvm)   _ = dvm.LoadAsync(force: true);
        else if (CurrentViewModel is Ec2ViewModel evm)         _ = evm.LoadAsync(force: true);
        else if (CurrentViewModel is S3ViewModel svm)          _ = svm.LoadAsync(force: true);
        else if (CurrentViewModel is IamViewModel ivm)         _ = ivm.LoadAsync(force: true);
        else if (CurrentViewModel is BillingViewModel bvm)     _ = bvm.LoadAsync(force: true);
        else if (CurrentViewModel is CloudWatchViewModel cwvm) _ = cwvm.LoadAsync(force: true);
        else if (CurrentViewModel is GuardDutyViewModel gdvm)  _ = gdvm.LoadAsync(force: true);
    }

    [RelayCommand]
    private void SwitchAccount(AwsAccount? account)
    {
        if (account == null) return;
        _accounts.SetActiveAccount(account.Id);
        IsAccountMenuOpen = false;
    }

    [RelayCommand]
    private void OpenAccountSettings()
    {
        IsAccountMenuOpen = false;
        NavigateTo(NavigationPage.Settings);
    }

    [RelayCommand]
    private void NavigateTo(NavigationPage page)
    {
        // Pro-only sections are blocked on the Free tier — show the upgrade prompt
        // and keep the sidebar selection on the current page.
        if (IsProOnly(page) && !IsPro)
        {
            _upgrade.Prompt($"{PageDisplayName(page)} is part of Atlas Pro. Upgrade to unlock it.");
            OnPropertyChanged(nameof(CurrentPage)); // restore the RadioButton selection
            return;
        }

        // Don't reload if we're already on this page
        if (CurrentPage == page && CurrentViewModel != null) return;

        CurrentPage = page;
        _analytics.TrackPageView(PageDisplayName(page));
        CurrentViewModel = page switch
        {
            NavigationPage.Dashboard   => DashboardVM,
            NavigationPage.EC2         => Ec2VM,
            NavigationPage.S3          => S3VM,
            NavigationPage.IAM         => IamVM,
            NavigationPage.Billing     => BillingVM,
            NavigationPage.CloudWatch  => CloudWatchVM,
            NavigationPage.GuardDuty   => GuardDutyVM,
            NavigationPage.Settings    => SettingsVM,
            NavigationPage.Contact     => ContactVM,
            _                          => DashboardVM
        };

        // Only kick off a load if data is stale — ViewModels self-manage freshness
        if (CurrentViewModel is DashboardViewModel dvm)   _ = dvm.LoadAsync();
        if (CurrentViewModel is Ec2ViewModel evm)         _ = evm.LoadAsync();
        if (CurrentViewModel is S3ViewModel svm)          _ = svm.LoadAsync();
        if (CurrentViewModel is IamViewModel ivm)         _ = ivm.LoadAsync();
        if (CurrentViewModel is BillingViewModel bvm)     _ = bvm.LoadAsync();
        if (CurrentViewModel is CloudWatchViewModel cwvm) _ = cwvm.LoadAsync();
        if (CurrentViewModel is GuardDutyViewModel gdvm)  _ = gdvm.LoadAsync();
    }

    partial void OnSelectedAccountChanged(AwsAccount? value)
    {
        if (!_suppressAccountCallback && value != null)
            _accounts.SetActiveAccount(value.Id);
    }

    private void RefreshAccounts()
    {
        Accounts.Clear();
        foreach (var a in _accounts.Accounts) Accounts.Add(a);

        _suppressAccountCallback = true;
        SelectedAccount = _accounts.ActiveAccount;
        _suppressAccountCallback = false;

        OnPropertyChanged(nameof(ActiveAccountName));
        OnPropertyChanged(nameof(ActiveAccountRegion));
        OnPropertyChanged(nameof(ActiveAccountInitials));
        OnPropertyChanged(nameof(HasActiveAccount));
    }

    private void RefreshRegion()
    {
        ActiveRegionCode = _accounts.ActiveRegion;
        ActiveRegionDisplay = RegionDisplayName(_accounts.ActiveRegion);
    }

    private void InitializePaletteCommands()
    {
        var commands = new List<PaletteCommand>
        {
            // ── Navigation ──────────────────────────────────────────────
            new() { Title = "Go to Dashboard",       Category = "Navigate", Icon = "",
                    Keywords = ["dashboard", "home", "overview"],
                    Execute = () => NavigateTo(NavigationPage.Dashboard) },

            new() { Title = "Go to EC2 Instances",   Category = "Navigate", Icon = "",
                    Keywords = ["ec2", "server", "instance", "virtual", "machine"],
                    Execute = () => NavigateTo(NavigationPage.EC2) },

            new() { Title = "Go to S3 Buckets",      Category = "Navigate", Icon = "",
                    Keywords = ["s3", "storage", "bucket", "files", "objects"],
                    Execute = () => NavigateTo(NavigationPage.S3) },

            new() { Title = "Go to IAM",             Category = "Navigate", Icon = "",
                    Subtitle = "Users, roles, groups and policies",
                    Keywords = ["iam", "users", "roles", "groups", "policies", "identity", "access"],
                    Execute = () => NavigateTo(NavigationPage.IAM) },

            new() { Title = "Go to Billing",         Category = "Navigate", Icon = "",
                    Subtitle = "Cost breakdown, trends and CSV export",
                    Keywords = ["billing", "cost", "invoice", "charges", "expense", "csv", "export"],
                    Execute = () => NavigateTo(NavigationPage.Billing) },
            new() { Title = "Go to CloudWatch",      Category = "Navigate", Icon = "",
                    Subtitle = "Alarms and monitoring",
                    Keywords = ["cloudwatch", "alarms", "metrics", "monitoring", "alerts"],
                    Execute = () => NavigateTo(NavigationPage.CloudWatch) },
            new() { Title = "Go to GuardDuty",       Category = "Navigate", Icon = "",
                    Subtitle = "Threat detection findings",
                    Keywords = ["guardduty", "guard", "threats", "findings", "security", "detection"],
                    Execute = () => NavigateTo(NavigationPage.GuardDuty) },
            new() { Title = "Go to Settings",        Category = "Navigate", Icon = "",
                    Keywords = ["settings", "config", "accounts", "preferences", "keys"],
                    Execute = () => NavigateTo(NavigationPage.Settings) },
            new() { Title = "Contact & Feedback",    Category = "Navigate", Icon = "",
                    Subtitle = "Report a bug or send a suggestion",
                    Keywords = ["contact", "feedback", "bug", "report", "suggestion", "help"],
                    Execute = () => NavigateTo(NavigationPage.Contact) },

            // ── Appearance ──────────────────────────────────────────────
            new() { Title = "Toggle Theme",          Category = "Appearance", Icon = "",
                    Subtitle = "Switch between dark and light mode",
                    Keywords = ["dark", "light", "theme", "color", "appearance", "mode"],
                    Execute = () => ToggleThemeCommand.Execute(null) },

            // ── General ─────────────────────────────────────────────────
            new() { Title = "Refresh",               Category = "General", Icon = "",
                    Subtitle = "Reload data for the current view",
                    Keywords = ["reload", "refresh", "update", "sync", "fetch"],
                    Execute = ReloadCurrentView },

            new() { Title = "Manage Accounts",       Category = "General", Icon = "",
                    Keywords = ["account", "accounts", "add", "credentials", "switch"],
                    Execute = () => NavigateTo(NavigationPage.Settings) },

            // ── EC2 ─────────────────────────────────────────────────────
            new() { Title = "Start EC2 Instance(s)", Category = "EC2", Icon = "",
                    Keywords = ["start", "run", "launch", "instance", "ec2"],
                    Execute = () => { NavigateTo(NavigationPage.EC2); Ec2VM.StartInstanceCommand.Execute(null); } },

            new() { Title = "Stop EC2 Instance(s)",  Category = "EC2", Icon = "",
                    Keywords = ["stop", "halt", "shutdown", "instance", "ec2"],
                    Execute = () => { NavigateTo(NavigationPage.EC2); Ec2VM.StopInstanceCommand.Execute(null); } },

            new() { Title = "Reboot EC2 Instance(s)", Category = "EC2", Icon = "",
                    Keywords = ["reboot", "restart", "instance", "ec2"],
                    Execute = () => { NavigateTo(NavigationPage.EC2); Ec2VM.RebootInstanceCommand.Execute(null); } },

            new() { Title = "Terminate EC2 Instance(s)", Category = "EC2", Icon = "",
                    Keywords = ["terminate", "delete", "destroy", "instance", "ec2"],
                    Execute = () => { NavigateTo(NavigationPage.EC2); Ec2VM.TerminateInstanceCommand.Execute(null); } },

            // ── S3 ──────────────────────────────────────────────────────
            new() { Title = "Create S3 Bucket",     Category = "S3", Icon = "",
                    Keywords = ["create", "bucket", "new", "s3", "add"],
                    Execute = () => { NavigateTo(NavigationPage.S3); S3VM.OpenCreateBucketCommand.Execute(null); } },

            new() { Title = "Upload File to S3",    Category = "S3", Icon = "",
                    Keywords = ["upload", "file", "s3", "put", "send"],
                    Execute = () => { NavigateTo(NavigationPage.S3); S3VM.UploadFileCommand.Execute(null); } },
        };

        Palette.Initialize(commands);
    }

    private static string GetInitials(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return "?";
        var parts = name.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length >= 2)
            return $"{char.ToUpper(parts[0][0])}{char.ToUpper(parts[1][0])}";
        return name[..Math.Min(2, name.Length)].ToUpper();
    }
}
