using System.Collections.ObjectModel;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.AWS;

namespace Atlas.ViewModels;

public record DailyBar(DailyCost Cost, double Height, string DayLabel, bool IsToday)
{
    public string Tooltip => Cost.Amount > 0
        ? $"{Cost.Date:d MMM}  {Cost.Amount:N2}"
        : Cost.Date.ToString("d MMM");
}

public record ServiceCostRow(string ServiceName, decimal Amount, string Currency, double WidthPercent)
{
    public string AmountText    => $"{Currency} {Amount:N2}";
    public string PercentText   => $"{WidthPercent:N0}%";
    public GridLength FillLength  => new(Math.Max(1, WidthPercent), GridUnitType.Star);
    public GridLength EmptyLength => new(Math.Max(0, 100 - WidthPercent), GridUnitType.Star);
}

public partial class DashboardViewModel : AsyncViewModel
{
    private readonly IDashboardService    _dashboard;
    private readonly IAccountService      _accounts;
    private readonly ISearchService       _search;
    private readonly ILicenseService      _license;
    private readonly ISecurityAuditService _audit;
    private readonly IDialogService       _dialog;

    private CancellationTokenSource? _searchCts;
    private CancellationTokenSource? _auditCts;
    private readonly EventHandler     _licenseChangedHandler;

    private DateOnly _selectedMonth = new DateOnly(DateTime.Now.Year, DateTime.Now.Month, 1);

    [ObservableProperty] private DashboardSummary? _summary;
    [ObservableProperty] private string _lastRefreshedText = "Never";

    // ── Cached computed lists (rebuilt after each successful load) ────────────
    private List<DailyBar>       _dailyBarsCache      = [];
    private List<ServiceCostRow> _serviceCostRowsCache = [];

    // ── Pro status ────────────────────────────────────────────────────────
    [ObservableProperty] private bool _isPro;

    // ── Month navigation ──────────────────────────────────────────────────
    public string SelectedMonthText => _selectedMonth.ToString("MMMM yyyy");
    public bool IsCurrentMonth      => _selectedMonth.Year == DateTime.Now.Year && _selectedMonth.Month == DateTime.Now.Month;
    public bool CanGoNext           => !IsCurrentMonth;
    public bool CanGoPrev           => true;

    [RelayCommand]
    private void PreviousMonth()
    {
        _selectedMonth = _selectedMonth.AddMonths(-1);
        NotifyMonthChanged();
        _ = LoadAsync(force: true);
    }

    [RelayCommand]
    private void NextMonth()
    {
        if (!CanGoNext) return;
        _selectedMonth = _selectedMonth.AddMonths(1);
        NotifyMonthChanged();
        _ = LoadAsync(force: true);
    }

    [RelayCommand]
    private void GoToCurrentMonth()
    {
        if (IsCurrentMonth) return;
        _selectedMonth = new DateOnly(DateTime.Now.Year, DateTime.Now.Month, 1);
        NotifyMonthChanged();
        _ = LoadAsync(force: true);
    }

    private void NotifyMonthChanged()
    {
        OnPropertyChanged(nameof(SelectedMonthText));
        OnPropertyChanged(nameof(IsCurrentMonth));
        OnPropertyChanged(nameof(CanGoNext));
        OnPropertyChanged(nameof(ShowForecast));
        OnPropertyChanged(nameof(CostSectionSubtitle));
        OnPropertyChanged(nameof(CurrentMonthLabel));
    }

    // ── Cost text ─────────────────────────────────────────────────────────
    public string CurrentMonthLabel    => IsCurrentMonth ? "This month (MTD)" : "Month total";
    public string CostSectionSubtitle  => IsCurrentMonth
        ? "Current calendar month · Blended cost"
        : $"{_selectedMonth:MMMM yyyy} · Blended cost";

    public bool ShowForecast => IsCurrentMonth;

    public string CurrentMonthCostText => Summary == null ? "—"
        : $"{Summary.CostCurrency} {Summary.CurrentMonthCost:N2}";
    public string LastMonthCostText    => Summary == null ? "—"
        : $"{Summary.CostCurrency} {Summary.LastMonthCost:N2}";
    public string ForecastedCostText   => Summary == null ? "—"
        : $"{Summary.CostCurrency} {Summary.ForecastedMonthCost:N2}";

    public string CostTrendText
    {
        get
        {
            if (Summary == null || Summary.LastMonthCost == 0) return string.Empty;
            var pct = (Summary.CurrentMonthCost - Summary.LastMonthCost) / Summary.LastMonthCost * 100;
            return pct >= 0 ? $"▲ {pct:N1}% vs prev month" : $"▼ {Math.Abs(pct):N1}% vs prev month";
        }
    }
    public bool CostTrendUp => Summary != null && Summary.CurrentMonthCost > Summary.LastMonthCost;

    // ── Daily bars ────────────────────────────────────────────────────────
    public List<DailyBar> DailyBars => _dailyBarsCache;

    private static List<DailyBar> BuildDailyBars(DashboardSummary? summary, DateOnly month)
    {
        if (summary == null) return [];
        var today      = DateOnly.FromDateTime(DateTime.Today);
        var daysInMonth = DateTime.DaysInMonth(month.Year, month.Month);
        var costByDate = summary.DailyCosts.ToDictionary(d => d.Date, d => d.Amount);
        var max        = costByDate.Values.DefaultIfEmpty(0m).Max();

        return Enumerable.Range(1, daysInMonth).Select(day =>
        {
            var date   = new DateOnly(month.Year, month.Month, day);
            var amount = costByDate.TryGetValue(date, out var a) ? a : 0m;
            var height = max > 0 && amount > 0 ? Math.Max(3, (double)amount / (double)max * 64) : 0;
            var label  = day == 1 || day % 5 == 0 ? day.ToString() : string.Empty;
            return new DailyBar(new DailyCost { Date = date, Amount = amount }, height, label, date == today);
        }).ToList();
    }

    public string DailyBarsStartDate => Summary?.DailyCosts?.Count > 0
        ? Summary.DailyCosts[0].Date.ToString("d MMM") : string.Empty;
    public string DailyBarsEndDate   => Summary?.DailyCosts?.Count > 0
        ? Summary.DailyCosts[^1].Date.ToString("d MMM") : string.Empty;

    // ── Service cost breakdown ────────────────────────────────────────────
    public List<ServiceCostRow> ServiceCostRows => _serviceCostRowsCache;

    public bool HasServiceCosts => _serviceCostRowsCache.Count > 0;

    private static List<ServiceCostRow> BuildServiceCostRows(DashboardSummary? summary)
    {
        var services = summary?.ServiceCosts;
        if (services == null || services.Count == 0) return [];
        var total = (double)services.Sum(s => s.Amount);
        if (total == 0) return [];
        return services
            .Take(8)
            .Select(s => new ServiceCostRow(
                ShortServiceName(s.ServiceName),
                s.Amount,
                s.Currency,
                (double)s.Amount / total * 100))
            .ToList();
    }

    private static string ShortServiceName(string name) => name
        .Replace("Amazon ", "")
        .Replace("AWS ", "")
        .Replace("Amazon Web Services ", "");

    // ── Account details ───────────────────────────────────────────────────
    public string AccountIdText     => Summary?.AccountId    ?? "—";
    public string AccountArnText    => Summary?.AccountArn   ?? "—";
    public string AccountRegionText => Summary?.Region       ?? "—";
    public string AccountAliasText  => string.IsNullOrWhiteSpace(Summary?.AccountAlias) ? "—" : Summary.AccountAlias;

    // ── Search ────────────────────────────────────────────────────────────
    [ObservableProperty] private string _searchQuery = string.Empty;
    [ObservableProperty] private bool   _isSearching;
    [ObservableProperty] private bool   _searchPanelVisible;
    [ObservableProperty] private string? _searchErrorMessage;
    [ObservableProperty] private ObservableCollection<SearchResult> _searchResults = [];

    public Action<SearchResult>? NavigateToResultRequested  { get; set; }
    public Action<NavigationPage>? NavigateToPageRequested  { get; set; }
    /// <summary>Fired when the user completes "Import from AWS" in the onboarding wizard.</summary>
    public Action<string, string>? ImportFromAwsRequested   { get; set; }

    // ── Onboarding (first run — no accounts configured) ───────────────────────
    public bool IsFirstRun => _accounts.Accounts.Count == 0;

    [ObservableProperty] private bool _showNextSteps;
    [ObservableProperty] private bool _showTerraformStep;
    [ObservableProperty] private string? _terraformProjectPath;

    public bool HasActiveAccount => _accounts.ActiveAccount != null;
    public bool HasSearchResults => SearchResults.Count > 0;
    public bool SearchIsEmpty    => !string.IsNullOrWhiteSpace(SearchQuery) && SearchResults.Count == 0 && !IsSearching;

    // ── Security Audit ────────────────────────────────────────────────────
    [ObservableProperty] private SecurityAuditResult? _auditResult;
    [ObservableProperty] private bool    _isAuditLoading;
    [ObservableProperty] private string  _auditStatusText = "Not run yet";

    public bool HasAuditResults => AuditResult?.Findings.Count > 0;

    public string AuditOverallIcon => AuditResult?.OverallSeverity switch
    {
        FindingSeverity.Critical => "",
        FindingSeverity.Warning  => "",
        _                        => ""
    };

    // ── Constructor ───────────────────────────────────────────────────────
    public DashboardViewModel(
        IDashboardService dashboard,
        IAccountService   accounts,
        ISearchService    search,
        ILicenseService   license,
        ISecurityAuditService audit,
        IDialogService    dialog)
    {
        _dashboard = dashboard;
        _accounts  = accounts;
        _search    = search;
        _license   = license;
        _audit     = audit;
        _dialog    = dialog;

        IsPro = _license.IsPro;
        _licenseChangedHandler = (_, _) => IsPro = _license.IsPro;
        _license.ProStatusChanged      += _licenseChangedHandler;
        _accounts.ActiveAccountChanged += OnAccountChanged;
    }

    // ── Search ────────────────────────────────────────────────────────────
    partial void OnSearchQueryChanged(string value)
    {
        _searchCts?.Cancel();
        _searchCts?.Dispose();
        _searchCts = null;

        if (string.IsNullOrWhiteSpace(value))
        {
            SearchPanelVisible = false;
            SearchResults.Clear();
            OnPropertyChanged(nameof(HasSearchResults));
            OnPropertyChanged(nameof(SearchIsEmpty));
            return;
        }

        SearchPanelVisible = true;
        _searchCts = new CancellationTokenSource();
        _ = RunSearchAsync(value.Trim(), _searchCts.Token);
    }

    private async Task RunSearchAsync(string query, CancellationToken ct)
    {
        IsSearching        = true;
        SearchErrorMessage = null;
        SearchResults.Clear();
        OnPropertyChanged(nameof(HasSearchResults));
        OnPropertyChanged(nameof(SearchIsEmpty));

        try
        {
            await Task.Delay(350, ct);
            var results = await _search.SearchAsync(query, ct);
            SearchResults.Clear();
            foreach (var r in results)
                SearchResults.Add(r);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { SearchErrorMessage = ex.Message; }
        finally
        {
            IsSearching = false;
            OnPropertyChanged(nameof(HasSearchResults));
            OnPropertyChanged(nameof(SearchIsEmpty));
        }
    }

    [RelayCommand]
    private void ClearSearch() => SearchQuery = string.Empty;

    // ── Onboarding commands ───────────────────────────────────────────────────
    [RelayCommand]
    private void OpenAddAccountDialog()
    {
        var result = _dialog.ShowAddAccountDialog();
        if (!result.Added) return;

        ShowNextSteps     = true;
        ShowTerraformStep = true;

        if (result.NextAction == "import"
            && result.StackName    is { Length: > 0 }
            && result.ProjectPath  is { Length: > 0 })
        {
            NavigateToPageRequested?.Invoke(NavigationPage.Stacks);
            ImportFromAwsRequested?.Invoke(result.StackName, result.ProjectPath);
        }
    }

    [RelayCommand]
    private void ConfigureTerraform()
    {
        var path = _dialog.ShowFolderPicker("Select your Terraform / OpenTofu project folder");
        if (path == null) return;
        TerraformProjectPath = path;
        ShowTerraformStep    = false;
    }

    [RelayCommand]
    private void SkipTerraform() => ShowTerraformStep = false;

    [RelayCommand] private void DismissNextSteps() => ShowNextSteps = false;
    [RelayCommand] private void GoToEc2()      => NavigateToPageRequested?.Invoke(NavigationPage.EC2);
    [RelayCommand] private void GoToS3()       => NavigateToPageRequested?.Invoke(NavigationPage.S3);
    [RelayCommand] private void GoToSettings() => NavigateToPageRequested?.Invoke(NavigationPage.Settings);

    [RelayCommand]
    private void NavigateToResult(SearchResult result)
    {
        NavigateToResultRequested?.Invoke(result);
        ClearSearch();
    }

    // ── Security Audit ────────────────────────────────────────────────────
    [RelayCommand]
    public async Task RunAuditAsync()
    {
        if (!IsPro || _accounts.ActiveAccount == null) return;

        _auditCts?.Cancel();
        _auditCts?.Dispose();
        var cts = new CancellationTokenSource();
        _auditCts = cts;

        IsAuditLoading = true;
        AuditStatusText = "Running audit…";

        try
        {
            AuditResult     = await _audit.RunAuditAsync(cts.Token);
            AuditStatusText = $"Last run {AuditResult.AuditedAt.ToLocalTime():HH:mm:ss}";
            OnPropertyChanged(nameof(HasAuditResults));
            OnPropertyChanged(nameof(AuditOverallIcon));
        }
        catch (OperationCanceledException)
        {
            AuditStatusText = "Audit cancelled";
        }
        catch (Exception ex)
        {
            AuditStatusText = $"Audit failed: {ex.Message}";
        }
        finally
        {
            IsAuditLoading = false;
            if (_auditCts == cts)
            {
                _auditCts = null;
                cts.Dispose();
            }
        }
    }

    // ── Dashboard load ────────────────────────────────────────────────────
    private void OnAccountChanged(object? s, EventArgs e)
    {
        // Cancel any in-flight search so it doesn't update results for the wrong account
        _searchCts?.Cancel();
        _searchCts?.Dispose();
        _searchCts = null;
        SearchPanelVisible = false;
        SearchResults.Clear();

        OnPropertyChanged(nameof(HasActiveAccount));
        OnPropertyChanged(nameof(IsFirstRun));
        _ = LoadAsync(force: true);
    }

    [RelayCommand]
    public async Task LoadAsync(bool force = false)
    {
        if (_accounts.ActiveAccount == null) return;
        if (!force && !IsDataStale) return;

        var ct = BeginLoad();
        try
        {
            Summary = await _dashboard.GetSummaryAsync(_selectedMonth, ct);
            LastRefreshedText = $"Updated {DateTime.Now:HH:mm:ss}";

            // Rebuild cached lists now that Summary is set
            _dailyBarsCache       = BuildDailyBars(Summary, _selectedMonth);
            _serviceCostRowsCache = BuildServiceCostRows(Summary);

            OnPropertyChanged(nameof(CurrentMonthCostText));
            OnPropertyChanged(nameof(LastMonthCostText));
            OnPropertyChanged(nameof(ForecastedCostText));
            OnPropertyChanged(nameof(CostTrendText));
            OnPropertyChanged(nameof(CostTrendUp));
            OnPropertyChanged(nameof(DailyBars));
            OnPropertyChanged(nameof(DailyBarsStartDate));
            OnPropertyChanged(nameof(DailyBarsEndDate));
            OnPropertyChanged(nameof(ServiceCostRows));
            OnPropertyChanged(nameof(HasServiceCosts));
            OnPropertyChanged(nameof(AccountIdText));
            OnPropertyChanged(nameof(AccountArnText));
            OnPropertyChanged(nameof(AccountRegionText));
            OnPropertyChanged(nameof(AccountAliasText));
            EndLoad();
        }
        catch (Exception ex)
        {
            HandleError("DashboardViewModel.LoadAsync", ex);
        }

        // Run security audit in background (Pro only)
        if (IsPro && _accounts.ActiveAccount != null && AuditResult == null)
            _ = RunAuditAsync();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _accounts.ActiveAccountChanged -= OnAccountChanged;
            _license.ProStatusChanged      -= _licenseChangedHandler;
            _searchCts?.Cancel();
            _searchCts?.Dispose();
            _auditCts?.Cancel();
            _auditCts?.Dispose();
        }
        base.Dispose(disposing);
    }
}
