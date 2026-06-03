using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.AWS;

namespace Atlas.ViewModels;

public partial class GuardDutyViewModel : AsyncViewModel
{
    private readonly IGuardDutyService _guardDuty;
    private readonly IAccountService   _accounts;

    private List<GuardDutyFindingModel> _allFindings = [];

    [ObservableProperty] private ObservableCollection<GuardDutyFindingModel> _findings = [];
    [ObservableProperty] private GuardDutyFindingModel? _selectedFinding;
    [ObservableProperty] private string _filterText      = string.Empty;
    [ObservableProperty] private string _severityFilter  = "All"; // All | HIGH | MEDIUM | LOW

    public bool HasActiveAccount => _accounts.ActiveAccount != null;
    public bool HasFindings      => Findings.Count > 0;

    public int TotalCount  => _allFindings.Count;
    public int HighCount   => _allFindings.Count(f => f.IsHigh);
    public int MediumCount => _allFindings.Count(f => f.IsMedium);
    public int LowCount    => _allFindings.Count(f => f.IsLow);

    public GuardDutyViewModel(IGuardDutyService guardDuty, IAccountService accounts)
    {
        _guardDuty = guardDuty;
        _accounts  = accounts;

        _accounts.ActiveAccountChanged += OnAccountChanged;
    }

    private void OnAccountChanged(object? s, EventArgs e)
    {
        OnPropertyChanged(nameof(HasActiveAccount));
        _ = LoadAsync(force: true);
    }

    [RelayCommand]
    public async Task LoadAsync(bool force = false)
    {
        if (_accounts.ActiveAccount == null) return;
        if (!force && !IsDataStale)          return;

        var ct = BeginLoad();
        try
        {
            _allFindings = [.. await _guardDuty.GetFindingsAsync(ct)];
            NotifyStats();
            ApplyFilter();
            EndLoad();
        }
        catch (Exception ex)
        {
            HandleError("GuardDutyViewModel.LoadAsync", ex);
        }
    }

    [RelayCommand]
    private async Task RefreshAsync() => await LoadAsync(force: true);

    partial void OnFilterTextChanged(string value)     => ApplyFilter();
    partial void OnSeverityFilterChanged(string value) => ApplyFilter();

    [RelayCommand]
    private void SetSeverityFilter(string severity) => SeverityFilter = severity;

    private void ApplyFilter()
    {
        var query  = FilterText.Trim();
        var result = _allFindings.AsEnumerable();

        if (SeverityFilter != "All")
            result = result.Where(f => f.SeverityLabel == SeverityFilter);

        if (!string.IsNullOrEmpty(query))
            result = result.Where(f =>
                f.Title.Contains(query,        StringComparison.OrdinalIgnoreCase) ||
                f.Type.Contains(query,         StringComparison.OrdinalIgnoreCase) ||
                f.ResourceType.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                f.Description.Contains(query,  StringComparison.OrdinalIgnoreCase));

        Findings.Clear();
        foreach (var f in result) Findings.Add(f);
        OnPropertyChanged(nameof(HasFindings));
    }

    private void NotifyStats()
    {
        OnPropertyChanged(nameof(TotalCount));
        OnPropertyChanged(nameof(HighCount));
        OnPropertyChanged(nameof(MediumCount));
        OnPropertyChanged(nameof(LowCount));
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
            _accounts.ActiveAccountChanged -= OnAccountChanged;
        base.Dispose(disposing);
    }
}
