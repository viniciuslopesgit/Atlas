using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Infrastructure.Logging;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.AWS;
using Atlas.Views;
using System.Collections.ObjectModel;
using System.Linq;
using System.Windows;

namespace Atlas.ViewModels;

public partial class Ec2ViewModel : AsyncViewModel
{
    private readonly IEc2Service _ec2;
    private readonly IAccountService _accounts;
    private readonly IDialogService _dialog;
    private readonly ILicenseService _license;
    private readonly IUpgradeService _upgrade;
    private readonly ISsmTerminalService _ssm;
    private List<Ec2InstanceModel> _allInstances = [];

    [ObservableProperty] private ObservableCollection<Ec2InstanceModel> _instances = [];
    [ObservableProperty] private string _filterText = string.Empty;
    [ObservableProperty] private string _statusFilter = "All";
    [ObservableProperty] private int  _selectedCount;
    [ObservableProperty] private bool _hasSelection;
    [ObservableProperty] private bool _areAllInstancesSelected;
    [ObservableProperty] private Ec2InstanceModel? _selectedInstance;
    [ObservableProperty] private string _selectedDetailTab = "Details";

    // ── Metrics ──────────────────────────────────────────────────────────────
    [ObservableProperty] private Ec2InstanceMetrics? _selectedMetrics;
    [ObservableProperty] private bool   _isMetricsLoading;
    [ObservableProperty] private string? _metricsError;

    private CancellationTokenSource? _metricsCts;

    public string CpuLastText      => FormatPercent(_selectedMetrics?.CpuUtilization);
    public string NetInLastText    => FormatBytes(_selectedMetrics?.NetworkIn);
    public string NetOutLastText   => FormatBytes(_selectedMetrics?.NetworkOut);
    public string DiskWriteLastText=> FormatBytes(_selectedMetrics?.DiskWriteBytes);

    public string[] StatusOptions { get; } = ["All", "running", "stopped", "pending", "terminated"];

    public List<Ec2InstanceModel> SelectedInstances { get; } = [];

    public void UpdateSelection(System.Collections.IList items)
    {
        SelectedInstances.Clear();
        foreach (Ec2InstanceModel item in items)
            SelectedInstances.Add(item);

        SelectedCount             = SelectedInstances.Count;
        HasSelection              = SelectedCount > 0;
        AreAllInstancesSelected   = Instances.Count > 0 && SelectedCount == Instances.Count;
        SelectedInstance          = SelectedCount == 1 ? SelectedInstances[0] : null;

        StartInstanceCommand.NotifyCanExecuteChanged();
        StopInstanceCommand.NotifyCanExecuteChanged();
        RebootInstanceCommand.NotifyCanExecuteChanged();
        TerminateInstanceCommand.NotifyCanExecuteChanged();
        ConnectSsmCommand.NotifyCanExecuteChanged();
    }

    public Ec2ViewModel(IEc2Service ec2, IAccountService accounts, IDialogService dialog,
                        ILicenseService license, IUpgradeService upgrade, ISsmTerminalService ssm)
    {
        _ec2 = ec2;
        _accounts = accounts;
        _dialog = dialog;
        _license = license;
        _upgrade = upgrade;
        _ssm = ssm;
        _accounts.ActiveAccountChanged += OnAccountChanged;
    }

    /// <summary>
    /// On the Free tier instance actions are limited to one instance at a time.
    /// Returns false (and surfaces the upgrade prompt) when a bulk action is attempted.
    /// </summary>
    private bool EnsureBulkAllowed()
    {
        if (_license.IsPro || SelectedInstances.Count <= 1) return true;
        _upgrade.Prompt("Bulk actions on multiple EC2 instances are a Pro feature. " +
                        "On Free you can start, stop or reboot one instance at a time.");
        return false;
    }

    private void OnAccountChanged(object? s, EventArgs e) => _ = LoadAsync(force: true);

    [RelayCommand]
    public async Task LoadAsync(bool force = false)
    {
        if (_accounts.ActiveAccount == null) return;
        if (!force && !IsDataStale) return;

        var ct = BeginLoad();
        try
        {
            _allInstances = (await _ec2.GetInstancesAsync(ct)).ToList();
            ApplyFilter();
            EndLoad();
        }
        catch (Exception ex)
        {
            HandleError("Ec2ViewModel.LoadAsync", ex);
        }
    }

    [RelayCommand]
    private async Task LaunchInstance()
    {
        var dialog = new LaunchInstanceDialog(_accounts.ActiveRegion, _ec2)
        {
            Owner = Application.Current.MainWindow
        };
        dialog.ShowDialog();
        if (!dialog.Confirmed || dialog.Result == null) return;

        var ct = BeginLoad();
        try
        {
            await _ec2.LaunchInstanceAsync(dialog.Result, ct);
            await Task.Delay(2000, ct); // allow AWS to reflect the new instance
            await LoadAsync(force: true);
        }
        catch (Exception ex)
        {
            HandleError("Ec2ViewModel.LaunchInstance", ex);
        }
    }

    partial void OnFilterTextChanged(string value) => ApplyFilter();
    partial void OnStatusFilterChanged(string value) => ApplyFilter();

    partial void OnSelectedInstanceChanged(Ec2InstanceModel? value)
    {
        SelectedDetailTab = "Details";

        _metricsCts?.Cancel();
        _metricsCts?.Dispose();
        _metricsCts = null;
        SelectedMetrics = null;
        MetricsError    = null;

        if (value == null) return;

        _metricsCts = new CancellationTokenSource();
        _ = LoadMetricsAsync(value.InstanceId, _metricsCts.Token);
    }

    partial void OnSelectedMetricsChanged(Ec2InstanceMetrics? value)
    {
        OnPropertyChanged(nameof(CpuLastText));
        OnPropertyChanged(nameof(NetInLastText));
        OnPropertyChanged(nameof(NetOutLastText));
        OnPropertyChanged(nameof(DiskWriteLastText));
    }

    private async Task LoadMetricsAsync(string instanceId, CancellationToken ct)
    {
        IsMetricsLoading = true;
        MetricsError     = null;
        try
        {
            SelectedMetrics = await _ec2.GetInstanceMetricsAsync(instanceId, ct);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { MetricsError = $"Could not load metrics: {ex.Message}"; }
        finally { IsMetricsLoading = false; }
    }

    private static string FormatPercent(IReadOnlyList<MetricPoint>? pts)
    {
        if (pts == null || pts.Count == 0) return "—";
        return $"{pts.OrderByDescending(p => p.Timestamp).First().Value:N1}%";
    }

    private static string FormatBytes(IReadOnlyList<MetricPoint>? pts)
    {
        if (pts == null || pts.Count == 0) return "—";
        var v = pts.OrderByDescending(p => p.Timestamp).First().Value;
        return v switch
        {
            >= 1_073_741_824 => $"{v / 1_073_741_824:N1} GB",
            >= 1_048_576     => $"{v / 1_048_576:N1} MB",
            >= 1_024         => $"{v / 1_024:N1} KB",
            _                => $"{v:N0} B"
        };
    }

    private void ApplyFilter()
    {
        var filtered = _allInstances.AsEnumerable();

        if (!string.IsNullOrWhiteSpace(FilterText))
            filtered = filtered.Where(i =>
                i.Name.Contains(FilterText, StringComparison.OrdinalIgnoreCase) ||
                i.InstanceId.Contains(FilterText, StringComparison.OrdinalIgnoreCase) ||
                i.PublicIpAddress.Contains(FilterText, StringComparison.OrdinalIgnoreCase));

        if (StatusFilter != "All")
            filtered = filtered.Where(i => i.State == StatusFilter);

        Instances = new ObservableCollection<Ec2InstanceModel>(filtered);
    }

    [RelayCommand(CanExecute = nameof(CanAct))]
    private async Task StartInstance()
    {
        if (!EnsureBulkAllowed()) return;
        if (!_dialog.Confirm("Start instances",
                $"Start {SelectedInstances.Count} instance(s)?\n\n{SelectedInstanceNames()}"))
            return;
        await ExecuteAction(id => _ec2.StartInstanceAsync(id), "starting");
    }

    [RelayCommand(CanExecute = nameof(CanAct))]
    private async Task StopInstance()
    {
        if (!EnsureBulkAllowed()) return;
        if (!_dialog.Confirm("Stop instances",
                $"Stop {SelectedInstances.Count} instance(s)?\n\n{SelectedInstanceNames()}"))
            return;
        await ExecuteAction(id => _ec2.StopInstanceAsync(id), "stopping");
    }

    [RelayCommand(CanExecute = nameof(CanAct))]
    private async Task RebootInstance()
    {
        if (!EnsureBulkAllowed()) return;
        if (!_dialog.Confirm("Reboot instances",
                $"Reboot {SelectedInstances.Count} instance(s)?\n\n{SelectedInstanceNames()}"))
            return;
        await ExecuteAction(id => _ec2.RebootInstanceAsync(id), "rebooting");
    }

    [RelayCommand(CanExecute = nameof(CanConnectSsm))]
    private async Task ConnectSsm()
    {
        var instance = SelectedInstance!;
        var region   = instance.Region.Length > 0 ? instance.Region : _accounts.ActiveRegion;
        try
        {
            await _ssm.OpenSessionAsync(instance.InstanceId, region);
        }
        catch (Exception ex)
        {
            var detail = ex.Message.Contains("not connected", StringComparison.OrdinalIgnoreCase)
                ? "The SSM Agent on this instance is not connected.\n\n" +
                  "To use SSM Session Manager the instance must:\n" +
                  "• Have the SSM Agent installed and running\n" +
                  "• Have the AmazonSSMManagedInstanceCore IAM policy attached\n" +
                  "• Be able to reach the SSM endpoints (internet or VPC endpoint)"
                : $"Could not start SSM session:\n\n{ex.Message}";

            _dialog.Confirm("SSM Connect failed", detail, DialogKind.Info);
        }
    }

    private bool CanConnectSsm() => SelectedInstance?.State == "running";

    [RelayCommand(CanExecute = nameof(CanAct))]
    private async Task TerminateInstance()
    {
        if (!EnsureBulkAllowed()) return;
        if (!_dialog.Confirm("Terminate instances",
                $"This will permanently terminate {SelectedInstances.Count} instance(s). This action cannot be undone.\n\n{SelectedInstanceNames()}",
                DialogKind.Danger))
            return;
        await ExecuteAction(id => _ec2.TerminateInstanceAsync(id), "terminating");
    }

    private string SelectedInstanceNames() =>
        string.Join("\n", SelectedInstances.Select(i => $"• {i.Name}  ({i.InstanceId})"));

    private bool CanAct() => SelectedInstances.Count > 0;

    private async Task ExecuteAction(Func<string, Task> action, string verb)
    {
        var ids = SelectedInstances.Select(i => i.InstanceId).ToList();
        var ct = BeginLoad();
        try
        {
            await Task.WhenAll(ids.Select(id => action(id)));
            await Task.Delay(1500, ct);
            await LoadAsync(force: true);
        }
        catch (Exception ex)
        {
            FileLogger.Error($"Ec2ViewModel action '{verb}' failed", ex);
            ErrorMessage = $"Error {verb} instance(s): {ex.Message}";
            EndLoad(false);
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _accounts.ActiveAccountChanged -= OnAccountChanged;
            _metricsCts?.Cancel();
            _metricsCts?.Dispose();
        }
        base.Dispose(disposing);
    }
}
