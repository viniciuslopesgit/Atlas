using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.AWS;

namespace Atlas.ViewModels;

public partial class CloudWatchViewModel : AsyncViewModel
{
    private readonly ICloudWatchService _cloudWatch;
    private readonly IAccountService    _accounts;

    private List<CloudWatchAlarmModel> _allAlarms = [];

    [ObservableProperty] private ObservableCollection<CloudWatchAlarmModel> _alarms = [];
    [ObservableProperty] private CloudWatchAlarmModel? _selectedAlarm;
    [ObservableProperty] private string _filterText     = string.Empty;
    [ObservableProperty] private string _stateFilter    = "All";  // All | ALARM | OK | INSUFFICIENT_DATA

    public bool HasActiveAccount => _accounts.ActiveAccount != null;
    public bool HasAlarms        => Alarms.Count > 0;

    public int TotalCount       => _allAlarms.Count;
    public int AlarmCount       => _allAlarms.Count(a => a.IsAlarm);
    public int OkCount          => _allAlarms.Count(a => a.IsOk);
    public int InsufficientCount => _allAlarms.Count(a => a.IsInsufficientData);

    public CloudWatchViewModel(ICloudWatchService cloudWatch, IAccountService accounts)
    {
        _cloudWatch = cloudWatch;
        _accounts   = accounts;

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
            _allAlarms = [.. await _cloudWatch.GetAlarmsAsync(ct)];
            NotifyStats();
            ApplyFilter();
            EndLoad();
        }
        catch (Exception ex)
        {
            HandleError("CloudWatchViewModel.LoadAsync", ex);
        }
    }

    [RelayCommand]
    private async Task RefreshAsync() => await LoadAsync(force: true);

    partial void OnFilterTextChanged(string value)  => ApplyFilter();
    partial void OnStateFilterChanged(string value) => ApplyFilter();

    [RelayCommand]
    private void SetStateFilter(string state) => StateFilter = state;

    private void ApplyFilter()
    {
        var query  = FilterText.Trim();
        var result = _allAlarms.AsEnumerable();

        if (StateFilter != "All")
            result = result.Where(a => a.State == StateFilter);

        if (!string.IsNullOrEmpty(query))
            result = result.Where(a =>
                a.Name.Contains(query,       StringComparison.OrdinalIgnoreCase) ||
                a.MetricName.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                a.Namespace.Contains(query,  StringComparison.OrdinalIgnoreCase) ||
                a.Description.Contains(query, StringComparison.OrdinalIgnoreCase));

        Alarms.Clear();
        foreach (var a in result) Alarms.Add(a);
        OnPropertyChanged(nameof(HasAlarms));
    }

    private void NotifyStats()
    {
        OnPropertyChanged(nameof(TotalCount));
        OnPropertyChanged(nameof(AlarmCount));
        OnPropertyChanged(nameof(OkCount));
        OnPropertyChanged(nameof(InsufficientCount));
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
            _accounts.ActiveAccountChanged -= OnAccountChanged;
        base.Dispose(disposing);
    }
}
