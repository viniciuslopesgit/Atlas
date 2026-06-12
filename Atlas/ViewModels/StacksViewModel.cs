using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Infrastructure.Database;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.Terraform;
using Atlas.Services.Terraform.Import;
using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;

namespace Atlas.ViewModels;

// ─── Drift diff line ─────────────────────────────────────────────────────────

public class DriftDiffLine
{
    public string Text { get; init; } = string.Empty;
    public string Fg   { get; init; } = "#94A3B8";
    public string Bg   { get; init; } = "#00000000";
}

// ─── Drift affected resource ──────────────────────────────────────────────────

public class DriftAffectedResource
{
    public string Address { get; init; } = string.Empty;
    public string Action  { get; init; } = string.Empty;

    public string ActionLabel => Action switch
    {
        "updated"   => "~",
        "replaced"  => "±",
        "destroyed" => "−",
        "created"   => "+",
        "read"      => "←",
        _           => "→"
    };

    public string ActionColor => Action switch
    {
        "updated"   => "#F59E0B",
        "replaced"  => "#F59E0B",
        "destroyed" => "#F87171",
        "created"   => "#4ADE80",
        _           => "#94A3B8"
    };
}

// ─── Drift CRON entry ────────────────────────────────────────────────────────

public partial class DriftCronEntryViewModel : ObservableObject
{
    private readonly StackEntryViewModel _parent;

    [ObservableProperty] private string _expression;

    public DriftCronEntryViewModel(string expression, StackEntryViewModel parent)
    {
        _expression = expression;
        _parent     = parent;
    }

    public DateTime? NextOccurrence
    {
        get
        {
            if (!TryParse(_expression, out var cron)) return null;
            return cron!.GetNextOccurrence(DateTime.UtcNow, TimeZoneInfo.Utc);
        }
    }

    public string Description
    {
        get
        {
            var next = NextOccurrence;
            if (next is null) return TryParse(_expression, out _) ? "No future occurrence" : "Invalid expression";
            return $"Next: {next.Value.ToLocalTime():MMM d, HH:mm}";
        }
    }

    public bool IsDue(DateTime since)
    {
        if (!TryParse(_expression, out var cron)) return false;
        var next = cron!.GetNextOccurrence(since.ToUniversalTime(), TimeZoneInfo.Utc);
        return next.HasValue && next.Value <= DateTime.UtcNow.ToUniversalTime();
    }

    partial void OnExpressionChanged(string value)
    {
        OnPropertyChanged(nameof(Description));
        OnPropertyChanged(nameof(NextOccurrence));
        _parent.NotifyCronChanged();
    }

    [RelayCommand]
    private void Delete() => _parent.RemoveCronEntry(this);

    private static bool TryParse(string expr, out Cronos.CronExpression? result)
    {
        try   { result = Cronos.CronExpression.Parse(expr, Cronos.CronFormat.Standard); return true; }
        catch { result = null; return false; }
    }
}

// ─── Run-level ViewModel ─────────────────────────────────────────────────────

public partial class StackRunViewModel : ObservableObject
{
    // ── Output buffer limits ──────────────────────────────────────────────────
    /// Maximum lines held in memory for display.
    private const int MaxDisplayLines  = 1500;
    /// Lines kept in the persisted JSON (avoids huge stacks.json files).
    private const int MaxPersistLines  = 300;
    /// Only flush to the UI property every N lines to avoid thrashing WPF.
    private const int NotifyEveryLines = 15;

    private readonly StackRun      _run;
    private readonly List<string>  _lines     = [];
    private readonly object        _lineLock  = new();
    private int                    _pending;
    private bool                   _wasTrimmed;
    private System.Timers.Timer?   _elapsedTimer;

    [ObservableProperty] private StackRunStatus _status;
    [ObservableProperty] private string         _output     = string.Empty;
    [ObservableProperty] private bool           _isExpanded;
    [ObservableProperty] private bool           _isFirst;
    [ObservableProperty] private bool           _isLast;

    public StackRunViewModel(StackRun run)
    {
        _run    = run;
        _status = run.Status;

        // Re-hydrate persisted output without triggering the flush path
        if (!string.IsNullOrEmpty(run.Output))
        {
            _lines.AddRange(run.Output.Split('\n'));
            _output = BuildDisplayText();
        }

        if (_status == StackRunStatus.Running)
            StartElapsedTimer();
    }

    public string TypeLabel => _run.Type == StackRunType.FixDrift ? "FIX" : _run.Type.ToString().ToUpper();
    public string StartedText  => _run.StartedAt.ToString("MMM d, HH:mm");
    public string DurationText
    {
        get
        {
            if (_status == StackRunStatus.Running)
            {
                var elapsed = DateTime.UtcNow - _run.StartedAt;
                return elapsed.TotalMinutes >= 1
                    ? $"{(int)elapsed.TotalMinutes}m {elapsed.Seconds:D2}s"
                    : $"{(int)elapsed.TotalSeconds}s";
            }
            return _run.DurationText;
        }
    }
    public string TriggerText  => _run.TriggerLabel ?? $"started by a {_run.Type.ToString().ToLower()} run";

    public string StatusBadgeText => _status switch
    {
        StackRunStatus.Running   => "RUNNING",
        StackRunStatus.Success   => "SUCCESS",
        StackRunStatus.Failed    => "FAILED",
        StackRunStatus.Cancelled => "CANCELLED",
        _                        => _status.ToString().ToUpper()
    };

    public string StatusColor => _status switch
    {
        StackRunStatus.Running   => "#3B82F6",
        StackRunStatus.Success   => "#4ADE80",
        StackRunStatus.Failed    => "#F87171",
        StackRunStatus.Cancelled => "#94A3B8",
        _                        => "#94A3B8"
    };

    [RelayCommand]
    private void ToggleOutput() => IsExpanded = !IsExpanded;

    [RelayCommand]
    private void CopyOutput()
    {
        if (!string.IsNullOrEmpty(Output))
            System.Windows.Clipboard.SetText(Output);
    }

    /// <summary>
    /// Appends a line to the output buffer. UI is updated at most every
    /// <see cref="NotifyEveryLines"/> lines to prevent WPF thrashing.
    /// The buffer is capped at <see cref="MaxDisplayLines"/> lines to
    /// prevent unbounded memory growth during large plan outputs.
    /// </summary>
    public void AppendOutput(string line)
    {
        lock (_lineLock)
        {
            // Split in case the SDK delivers multi-line chunks.
            // TrimEnd('\r') strips trailing CR from lines built with AppendLine (\r\n endings)
            // that arrive via r.FullOutput or r.Stderr — prevents display artefacts.
            foreach (var l in line.Split('\n', StringSplitOptions.None))
                _lines.Add(l.TrimEnd('\r'));

            // Trim oldest lines when we hit the ceiling
            if (_lines.Count > MaxDisplayLines + 200)
            {
                _lines.RemoveRange(0, 200);
                _wasTrimmed = true;
            }

            _pending++;
        }

        if (_pending >= NotifyEveryLines)
            FlushToUi();
    }

    public void Complete(StackRunStatus status)
    {
        _elapsedTimer?.Stop();
        _elapsedTimer?.Dispose();
        _elapsedTimer = null;

        _run.Status      = status;
        _run.CompletedAt = DateTime.UtcNow;
        Status           = status;

        // Final flush — always show full buffer on completion
        FlushToUi(persist: true);

        OnPropertyChanged(nameof(DurationText));
        OnPropertyChanged(nameof(StatusBadgeText));
        OnPropertyChanged(nameof(StatusColor));
    }

    private void StartElapsedTimer()
    {
        _elapsedTimer = new System.Timers.Timer(1000) { AutoReset = true };
        _elapsedTimer.Elapsed += (_, _) =>
            Application.Current?.Dispatcher.BeginInvoke(() =>
                OnPropertyChanged(nameof(DurationText)));
        _elapsedTimer.Start();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private void FlushToUi(bool persist = false)
    {
        string text;
        string persistText;

        lock (_lineLock)
        {
            _pending  = 0;
            text      = BuildDisplayText();
            persistText = string.Join("\n", _lines.Count <= MaxPersistLines
                ? _lines
                : _lines.GetRange(_lines.Count - MaxPersistLines, MaxPersistLines));
        }

        // Set model output synchronously so _repo.Save() sees it immediately after Complete().
        // StackRun is a plain POCO — no UI thread affinity required.
        if (persist) _run.Output = persistText;

        Application.Current?.Dispatcher.BeginInvoke(() => Output = text);
    }

    private string BuildDisplayText()
    {
        if (_lines.Count == 0) return string.Empty;

        var sb = new System.Text.StringBuilder();
        if (_wasTrimmed)
            sb.AppendLine($"[⚠ earlier output not shown — displaying last {_lines.Count} lines]");

        foreach (var l in _lines)
            sb.AppendLine(l);

        return sb.ToString();
    }
}

// ─── Stack-level ViewModel ───────────────────────────────────────────────────

public partial class StackEntryViewModel : ObservableObject
{
    private readonly StackEntry _entry;

    [ObservableProperty] private StackStatus   _status;
    [ObservableProperty] private bool          _isExpanded;
    [ObservableProperty] private string        _selectedTab       = "runs";
    [ObservableProperty] private DriftInterval _driftInterval     = DriftInterval.Off;
    [ObservableProperty] private DriftStatus   _driftStatus       = DriftStatus.Unknown;
    [ObservableProperty] private string?       _driftSummary;
    [ObservableProperty] private DateTime?     _lastDriftCheckAt;
    [ObservableProperty] private bool          _driftAcknowledged = false;
    [ObservableProperty] private string?       _driftPlanOutput;
    [ObservableProperty] private bool          _autoFixOnDrift    = false;
    [ObservableProperty] private string        _newCronExpression = string.Empty;

    public ObservableCollection<StackRunViewModel>      Runs                   { get; } = [];
    public ObservableCollection<StackEnvVarViewModel>   EnvVars                { get; } = [];
    public ObservableCollection<DriftDiffLine>          DriftDiffLines         { get; } = [];
    public ObservableCollection<DriftAffectedResource>  DriftAffectedResources { get; } = [];
    public ObservableCollection<DriftCronEntryViewModel> CronEntries           { get; } = [];

    public bool HasEnvVars  => EnvVars.Count > 0;
    public int  EnvVarCount => EnvVars.Count;

    /// <summary>Called by StacksViewModel when env var values need persisting.</summary>
    public Func<IReadOnlyList<StackEnvVar>, Task>? EnvVarSaveRequested { get; set; }

    public StackEntryViewModel(StackEntry entry)
    {
        _entry             = entry;
        _status            = entry.Status;
        _driftInterval     = entry.DriftInterval;
        _driftStatus       = entry.DriftStatus;
        _driftSummary      = entry.DriftSummary;
        _lastDriftCheckAt  = entry.LastDriftCheckAt;
        _driftAcknowledged = entry.DriftAcknowledged;
        _driftPlanOutput   = entry.DriftPlanOutput;
        _autoFixOnDrift    = entry.AutoFixOnDrift;

        if (!string.IsNullOrEmpty(_driftPlanOutput))
        {
            foreach (var l in ParseDiffLines(_driftPlanOutput))
                DriftDiffLines.Add(l);
            foreach (var r in ParseAffectedResources(_driftPlanOutput))
                DriftAffectedResources.Add(r);
        }

        foreach (var expr in entry.DriftCronExpressions)
            CronEntries.Add(new DriftCronEntryViewModel(expr, this));

        foreach (var r in entry.Runs.OrderByDescending(r => r.StartedAt))
            Runs.Add(new StackRunViewModel(r));

        // Re-hydrate env vars saved from a previous import
        foreach (var v in entry.EnvVars)
            EnvVars.Add(new StackEnvVarViewModel(v, SaveEnvVarsAsync));

        RefreshConnectors();
    }

    public string Name        => _entry.Name;
    public string ProjectPath => _entry.ProjectPath;
    public string CreatedText => _entry.CreatedAt.ToLocalTime().ToString("MMM d, yyyy");

    public string StatusBadgeText =>
        DriftStatus == DriftStatus.Checking ? "CHECKING DRIFT" :
        (DriftStatus == DriftStatus.Drifted && !DriftAcknowledged && _status == StackStatus.Ready) ? "DRIFTED" :
        _status switch
        {
            StackStatus.Ready    => "READY",
            StackStatus.Queued   => "QUEUED",
            StackStatus.Running  => "RUNNING",
            StackStatus.Finished => "FINISHED",
            StackStatus.Failed   => "FAILED",
            _                    => _status.ToString().ToUpper()
        };

    public string StatusBadgeColor =>
        DriftStatus == DriftStatus.Checking ? "#94A3B8" :
        (DriftStatus == DriftStatus.Drifted && !DriftAcknowledged && _status == StackStatus.Ready) ? "#F59E0B" :
        _status switch
        {
            StackStatus.Ready    => "#3B82F6",
            StackStatus.Queued   => "#FBBF24",
            StackStatus.Running  => "#3B82F6",
            StackStatus.Finished => "#4ADE80",
            StackStatus.Failed   => "#F87171",
            _                    => "#94A3B8"
        };

    public string StatusBadgeBg =>
        DriftStatus == DriftStatus.Checking ? "#1A94A3B8" :
        (DriftStatus == DriftStatus.Drifted && !DriftAcknowledged && _status == StackStatus.Ready) ? "#1AF59E0B" :
        _status switch
        {
            StackStatus.Ready    => "#1A3B82F6",
            StackStatus.Queued   => "#1AFBBF24",
            StackStatus.Running  => "#1A3B82F6",
            StackStatus.Finished => "#1A4ADE80",
            StackStatus.Failed   => "#1AF87171",
            _                    => "#1A94A3B8"
        };

    public int RunCount => _entry.Runs.Count;

    // ── Drift Detection ───────────────────────────────────────────────────────

    public bool DriftEnabled   => DriftInterval != DriftInterval.Off || CronEntries.Count > 0;
    public bool HasCronEntries => CronEntries.Count > 0;
    public bool ShowDriftBadge => DriftEnabled && DriftStatus != DriftStatus.Unknown;

    // State panels — mutually exclusive visibility helpers
    public bool ShowDriftClean   => DriftStatus == DriftStatus.Clean;
    public bool ShowDriftDrifted => DriftStatus == DriftStatus.Drifted && !DriftAcknowledged;
    public bool ShowDriftAcknow  => DriftStatus == DriftStatus.Drifted &&  DriftAcknowledged;

    public string DriftBadgeText => DriftStatus switch
    {
        DriftStatus.Checking                       => "Checking…",
        DriftStatus.Clean                          => "Clean",
        DriftStatus.Drifted when DriftAcknowledged => "Ignored",
        DriftStatus.Drifted                        => DriftSummary ?? "Drifted",
        DriftStatus.Error                          => "Check failed",
        _                                          => string.Empty
    };

    public string DriftBadgeColor => DriftStatus switch
    {
        DriftStatus.Checking                       => "#3B82F6",
        DriftStatus.Clean                          => "#4ADE80",
        DriftStatus.Drifted when DriftAcknowledged => "#94A3B8",
        DriftStatus.Drifted                        => "#F59E0B",
        DriftStatus.Error                          => "#F87171",
        _                                          => "#94A3B8"
    };

    public string DriftBadgeBg => DriftStatus switch
    {
        DriftStatus.Checking                       => "#1A3B82F6",
        DriftStatus.Clean                          => "#1A4ADE80",
        DriftStatus.Drifted when DriftAcknowledged => "#1A94A3B8",
        DriftStatus.Drifted                        => "#1AF59E0B",
        DriftStatus.Error                          => "#1AF87171",
        _                                          => "#1A94A3B8"
    };

    public string LastDriftText
    {
        get
        {
            if (LastDriftCheckAt is null) return "Never";
            var ago = DateTime.UtcNow - LastDriftCheckAt.Value;
            if (ago.TotalMinutes < 1)  return "Just now";
            if (ago.TotalHours   < 1)  return $"{(int)ago.TotalMinutes}m ago";
            if (ago.TotalDays    < 1)  return $"{(int)ago.TotalHours}h ago";
            return $"{(int)ago.TotalDays}d ago";
        }
    }

    public DateTime? NextDriftCheckAt
    {
        get
        {
            if (DriftInterval == DriftInterval.Off) return null;
            if (LastDriftCheckAt is null) return DateTime.UtcNow;
            return LastDriftCheckAt.Value + DriftInterval switch
            {
                DriftInterval.Hourly => TimeSpan.FromHours(1),
                DriftInterval.Daily  => TimeSpan.FromDays(1),
                DriftInterval.Weekly => TimeSpan.FromDays(7),
                _                    => TimeSpan.MaxValue
            };
        }
    }

    public string NextDriftText
    {
        get
        {
            if (DriftInterval == DriftInterval.Off && CronEntries.Count == 0) return "Disabled";
            if (DriftInterval == DriftInterval.Off) return "Via CRON";
            if (LastDriftCheckAt is null) return "Pending";
            var next = NextDriftCheckAt!.Value;
            var left = next - DateTime.UtcNow;
            if (left.TotalSeconds <= 0) return "Overdue";
            if (left.TotalMinutes  < 1) return "< 1 min";
            if (left.TotalHours    < 1) return $"In {(int)left.TotalMinutes}m";
            if (left.TotalDays     < 1) return $"In {(int)left.TotalHours}h {left.Minutes}m";
            return $"In {(int)left.TotalDays}d";
        }
    }

    public bool IsDriftDue =>
        DriftStatus != DriftStatus.Checking &&
        Status      != StackStatus.Running  &&
        (IsIntervalDue || IsCronDue);

    private bool IsIntervalDue =>
        DriftInterval != DriftInterval.Off &&
        NextDriftCheckAt.HasValue &&
        DateTime.UtcNow >= NextDriftCheckAt.Value;

    private bool IsCronDue =>
        CronEntries.Count > 0 &&
        CronEntries.Any(c => c.IsDue(LastDriftCheckAt ?? DateTime.UtcNow.AddDays(-1)));

    // Partial hooks — keep _entry in sync and notify computed properties
    partial void OnDriftIntervalChanged(DriftInterval value)
    {
        _entry.DriftInterval = value;
        OnPropertyChanged(nameof(DriftEnabled));
        OnPropertyChanged(nameof(ShowDriftBadge));
        OnPropertyChanged(nameof(NextDriftText));
        DriftIntervalChanged?.Invoke(this);
    }

    partial void OnDriftStatusChanged(DriftStatus value)
    {
        _entry.DriftStatus = value;
        OnPropertyChanged(nameof(StatusBadgeText));
        OnPropertyChanged(nameof(StatusBadgeColor));
        OnPropertyChanged(nameof(StatusBadgeBg));
        OnPropertyChanged(nameof(DriftBadgeText));
        OnPropertyChanged(nameof(DriftBadgeColor));
        OnPropertyChanged(nameof(DriftBadgeBg));
        OnPropertyChanged(nameof(ShowDriftBadge));
        OnPropertyChanged(nameof(ShowDriftClean));
        OnPropertyChanged(nameof(ShowDriftDrifted));
        OnPropertyChanged(nameof(ShowDriftAcknow));
    }

    partial void OnDriftSummaryChanged(string? value) => _entry.DriftSummary = value;

    partial void OnLastDriftCheckAtChanged(DateTime? value)
    {
        _entry.LastDriftCheckAt = value;
        OnPropertyChanged(nameof(LastDriftText));
        OnPropertyChanged(nameof(NextDriftText));
    }

    partial void OnDriftAcknowledgedChanged(bool value)
    {
        _entry.DriftAcknowledged = value;
        OnPropertyChanged(nameof(StatusBadgeText));
        OnPropertyChanged(nameof(StatusBadgeColor));
        OnPropertyChanged(nameof(StatusBadgeBg));
        OnPropertyChanged(nameof(DriftBadgeText));
        OnPropertyChanged(nameof(DriftBadgeColor));
        OnPropertyChanged(nameof(DriftBadgeBg));
        OnPropertyChanged(nameof(ShowDriftDrifted));
        OnPropertyChanged(nameof(ShowDriftAcknow));
        DriftAcknowledgeChanged?.Invoke(this);
    }

    partial void OnDriftPlanOutputChanged(string? value)
    {
        _entry.DriftPlanOutput = value;
        var diffLines  = string.IsNullOrEmpty(value) ? [] : ParseDiffLines(value).ToList();
        var resources  = string.IsNullOrEmpty(value) ? [] : ParseAffectedResources(value).ToList();

        void Apply()
        {
            DriftDiffLines.Clear();
            foreach (var l in diffLines) DriftDiffLines.Add(l);
            DriftAffectedResources.Clear();
            foreach (var r in resources) DriftAffectedResources.Add(r);
        }

        if (Application.Current?.Dispatcher.CheckAccess() == true)
            Apply();
        else
            Application.Current?.Dispatcher.Invoke(Apply);
    }

    partial void OnAutoFixOnDriftChanged(bool value)
    {
        _entry.AutoFixOnDrift = value;
        AutoFixOnDriftChanged?.Invoke(this);
    }

    public void NotifyCronChanged()
    {
        _entry.DriftCronExpressions = [.. CronEntries.Select(c => c.Expression)];
        OnPropertyChanged(nameof(HasCronEntries));
        OnPropertyChanged(nameof(DriftEnabled));
        OnPropertyChanged(nameof(ShowDriftBadge));
        OnPropertyChanged(nameof(NextDriftText));
        CronEntriesChanged?.Invoke(this);
    }

    public void RemoveCronEntry(DriftCronEntryViewModel entry)
    {
        CronEntries.Remove(entry);
        NotifyCronChanged();
    }

    [RelayCommand]
    private void AddCronEntry()
    {
        var expr = NewCronExpression.Trim();
        if (string.IsNullOrEmpty(expr)) return;
        try { Cronos.CronExpression.Parse(expr, Cronos.CronFormat.Standard); }
        catch { return; }
        CronEntries.Add(new DriftCronEntryViewModel(expr, this));
        NewCronExpression = string.Empty;
        // CRON schedule takes precedence — interval must be Off
        if (DriftInterval != DriftInterval.Off)
            DriftInterval = DriftInterval.Off;
        NotifyCronChanged();
    }

    public Action<StackEntryViewModel>? DriftCheckRequested    { get; set; }
    public Action<StackEntryViewModel>? DriftIntervalChanged   { get; set; }
    public Action<StackEntryViewModel>? DriftFixRequested      { get; set; }
    public Action<StackEntryViewModel>? DriftAcknowledgeChanged { get; set; }
    public Action<StackEntryViewModel>? AutoFixOnDriftChanged  { get; set; }
    public Action<StackEntryViewModel>? CronEntriesChanged     { get; set; }

    [RelayCommand]
    private void SetDriftInterval(string intervalName)
    {
        if (Enum.TryParse<DriftInterval>(intervalName, out var interval))
            DriftInterval = interval;
    }

    [RelayCommand]
    private void SelectDriftTab() { IsExpanded = true; SelectedTab = "drift"; }

    [RelayCommand]
    private void CheckDriftNow()
    {
        if (!DriftEnabled || DriftStatus == DriftStatus.Checking) return;
        DriftCheckRequested?.Invoke(this);
    }

    [RelayCommand]
    private void IgnoreDrift() => DriftAcknowledged = true;

    [RelayCommand]
    private void FixDrift()
    {
        if (DriftStatus != DriftStatus.Drifted) return;
        IsExpanded  = true;
        SelectedTab = "runs";
        DriftFixRequested?.Invoke(this);
    }

    public void UpdateDriftResult(DriftStatus status, string? summary, string? planOutput, DateTime checkedAt)
    {
        Application.Current.Dispatcher.Invoke(() =>
        {
            DriftAcknowledged = false;
            DriftSummary      = summary;
            DriftPlanOutput   = planOutput;
            DriftStatus       = status;
            LastDriftCheckAt  = checkedAt;
        });
    }

    private static IEnumerable<DriftDiffLine> ParseDiffLines(string raw)
    {
        foreach (var rawLine in raw.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            var t    = line.TrimStart();
            if (t.StartsWith("+ ") || t.StartsWith("+\""))
                yield return new DriftDiffLine { Text = line, Fg = "#4ADE80", Bg = "#0D4ADE80" };
            else if (t.StartsWith("- ") || t.StartsWith("-\""))
                yield return new DriftDiffLine { Text = line, Fg = "#F87171", Bg = "#0DF87171" };
            else if (t.StartsWith("~ ") || t.StartsWith("->"))
                yield return new DriftDiffLine { Text = line, Fg = "#F59E0B", Bg = "#0DF59E0B" };
            else if (t.StartsWith("# "))
                yield return new DriftDiffLine { Text = line, Fg = "#93C5FD", Bg = "#00000000" };
            else
                yield return new DriftDiffLine { Text = line, Fg = "#94A3B8",  Bg = "#00000000" };
        }
    }

    private static IEnumerable<DriftAffectedResource> ParseAffectedResources(string raw)
    {
        foreach (var rawLine in raw.Split('\n'))
        {
            var t = rawLine.TrimStart();
            if (!t.StartsWith("# ")) continue;
            var willIdx = t.IndexOf(" will be ", StringComparison.OrdinalIgnoreCase);
            if (willIdx < 0) continue;
            var addr = t[2..willIdx].Trim();
            var rest = t[(willIdx + 9)..];
            var action = rest switch
            {
                _ when rest.StartsWith("updated",   StringComparison.OrdinalIgnoreCase) => "updated",
                _ when rest.StartsWith("replaced",  StringComparison.OrdinalIgnoreCase) => "replaced",
                _ when rest.StartsWith("destroyed", StringComparison.OrdinalIgnoreCase) => "destroyed",
                _ when rest.StartsWith("created",   StringComparison.OrdinalIgnoreCase) => "created",
                _ when rest.StartsWith("read",      StringComparison.OrdinalIgnoreCase) => "read",
                _                                                                        => "changed"
            };
            yield return new DriftAffectedResource { Address = addr, Action = action };
        }
    }

    // ── Stack operations ──────────────────────────────────────────────────────

    [RelayCommand]
    private void ToggleExpand() => IsExpanded = !IsExpanded;

    public void UpdateStatus(StackStatus status)
    {
        _entry.Status = status;
        Status        = status;
        OnPropertyChanged(nameof(StatusBadgeText));
        OnPropertyChanged(nameof(StatusBadgeColor));
        OnPropertyChanged(nameof(StatusBadgeBg));
    }

    public Action<StackEntryViewModel, StackRunType>? RunRequested { get; set; }
    public Action<StackEntryViewModel>?               RemoveRequested { get; set; }

    [RelayCommand] private void RunInit()             => RunRequested?.Invoke(this, StackRunType.Init);
    [RelayCommand] private void RunImport()           => RunRequested?.Invoke(this, StackRunType.Import);
    [RelayCommand] private void RunApply()            => RunRequested?.Invoke(this, StackRunType.Apply);
    [RelayCommand] private void RemoveStack()         => RemoveRequested?.Invoke(this);
    [RelayCommand] private void SelectRunsTab()       { IsExpanded = true; SelectedTab = "runs"; }
    [RelayCommand] private void SelectEnvironmentTab(){ IsExpanded = true; SelectedTab = "environment"; }

    /// <summary>
    /// Loads (or reloads) extracted env vars into the UI collection.
    /// Safe to call from any thread — dispatches to UI.
    /// </summary>
    public void LoadEnvVars(IReadOnlyList<StackEnvVar> vars)
    {
        Application.Current.Dispatcher.Invoke(() =>
        {
            EnvVars.Clear();
            foreach (var v in vars)
                EnvVars.Add(new StackEnvVarViewModel(v, SaveEnvVarsAsync));

            OnPropertyChanged(nameof(HasEnvVars));
            OnPropertyChanged(nameof(EnvVarCount));

            if (vars.Count > 0)
                SelectedTab = "environment";
        });
    }

    private async Task SaveEnvVarsAsync()
    {
        var models = EnvVars.Select(v => v.GetModel()).ToList();
        if (EnvVarSaveRequested is not null)
            await EnvVarSaveRequested(models);
    }

    public StackRunViewModel AddRun(StackRun run)
    {
        _entry.Runs.Add(run);
        var vm = new StackRunViewModel(run);
        Application.Current.Dispatcher.Invoke(() =>
        {
            Runs.Insert(0, vm);
            RefreshConnectors();
        });
        return vm;
    }

    private void RefreshConnectors()
    {
        for (int i = 0; i < Runs.Count; i++)
        {
            Runs[i].IsFirst = i == 0;
            Runs[i].IsLast  = i == Runs.Count - 1;
        }
    }

    public void NotifyRunCountChanged() => OnPropertyChanged(nameof(RunCount));
}

// ─── Page ViewModel ──────────────────────────────────────────────────────────

public partial class StacksViewModel : ObservableObject
{
    private readonly IStackRepository          _repo;
    private readonly ITerraformProjectManager  _projectManager;
    private readonly IImportService            _importer;
    private readonly IAccountService           _accounts;
    private readonly ITerraformCliWrapper      _cli;
    private readonly IStackEnvVarRepository    _envVarRepo;
    private readonly IDialogService            _dialog;
    private System.Timers.Timer?               _driftTimer;

    public ObservableCollection<StackEntryViewModel> Stacks         { get; } = [];
    public ObservableCollection<StackEntryViewModel> FilteredStacks { get; } = [];

    public string[] StatusOptions { get; } = ["All", "Ready", "Running", "Drifted", "Failed"];

    [ObservableProperty] private bool   _isLoading;
    [ObservableProperty] private string _searchText   = string.Empty;
    [ObservableProperty] private string _statusFilter = "All";

    public int  TotalCount         => Stacks.Count;
    public int  RunningCount       => Stacks.Count(vm => vm.Status == StackStatus.Running);
    public int  DriftedCount       => Stacks.Count(vm => vm.DriftStatus == DriftStatus.Drifted && !vm.DriftAcknowledged);
    public int  FailedCount        => Stacks.Count(vm => vm.Status == StackStatus.Failed);
    public bool HasNoFilterResults => Stacks.Count > 0 && FilteredStacks.Count == 0;

    public StacksViewModel(
        IStackRepository          repo,
        ITerraformProjectManager  projectManager,
        IImportService            importer,
        IAccountService           accounts,
        ITerraformCliWrapper      cli,
        IStackEnvVarRepository    envVarRepo,
        IDialogService            dialog)
    {
        _repo           = repo;
        _envVarRepo     = envVarRepo;
        _projectManager = projectManager;
        _importer       = importer;
        _accounts       = accounts;
        _cli            = cli;
        _dialog         = dialog;

        Load();
        StartDriftMonitor();

        Stacks.CollectionChanged += (_, _) => { RefreshKpis(); ApplyFilter(); };
        ApplyFilter();
    }

    partial void OnSearchTextChanged(string value)   => ApplyFilter();
    partial void OnStatusFilterChanged(string value) => ApplyFilter();

    [RelayCommand]
    private void SetStatusFilter(string filter) => StatusFilter = filter;

    private bool Matches(StackEntryViewModel vm)
    {
        if (!string.IsNullOrWhiteSpace(SearchText) &&
            !vm.Name.Contains(SearchText, StringComparison.OrdinalIgnoreCase) &&
            !vm.ProjectPath.Contains(SearchText, StringComparison.OrdinalIgnoreCase))
            return false;

        return StatusFilter switch
        {
            "Ready"   => vm.Status == StackStatus.Ready,
            "Running" => vm.Status == StackStatus.Running,
            "Failed"  => vm.Status == StackStatus.Failed,
            "Drifted" => vm.DriftStatus == DriftStatus.Drifted && !vm.DriftAcknowledged,
            _         => true,
        };
    }

    private void ApplyFilter()
    {
        FilteredStacks.Clear();
        foreach (var vm in Stacks)
            if (Matches(vm)) FilteredStacks.Add(vm);
        OnPropertyChanged(nameof(HasNoFilterResults));
    }

    private void RefreshKpis()
    {
        OnPropertyChanged(nameof(TotalCount));
        OnPropertyChanged(nameof(RunningCount));
        OnPropertyChanged(nameof(DriftedCount));
        OnPropertyChanged(nameof(FailedCount));
    }

    // ── Create New Stack (header button) ──────────────────────────────────────

    [RelayCommand]
    private void CreateNewStack()
    {
        var result = _dialog.ShowCreateStackDialog();
        if (result is null) return;

        if (Stacks.Any(s => s.Name.Equals(result.StackName, StringComparison.OrdinalIgnoreCase)))
        {
            _dialog.Confirm("Stack already exists",
                $"A stack named \"{result.StackName}\" already exists. Choose a different name.",
                DialogKind.Info);
            return;
        }

        _ = BeginImportAsync(result.StackName, result.ProjectPath);
    }

    public void Load()
    {
        Stacks.Clear();
        foreach (var entry in _repo.GetAll().OrderByDescending(s => s.CreatedAt))
        {
            var vm = new StackEntryViewModel(entry);
            WireRunRequested(vm, entry);
            Stacks.Add(vm);

            // Populate env var values from the secure DB (fire-and-forget)
            if (entry.EnvVars.Count > 0)
                _ = PopulateEnvVarValuesAsync(vm, entry.Name);
        }
    }

    /// <summary>Loads decrypted values from the secure store into the in-memory VMs.</summary>
    private async Task PopulateEnvVarValuesAsync(StackEntryViewModel stackVm, string stackName)
    {
        var values = await _envVarRepo.GetTfVarsAsync(stackName);
        if (values.Count == 0) return;

        Application.Current.Dispatcher.Invoke(() =>
        {
            foreach (var envVm in stackVm.EnvVars)
            {
                if (values.TryGetValue(envVm.TfVarName, out var val))
                    envVm.SetValue(val);
            }
        });
    }

    private void WireRunRequested(StackEntryViewModel vm, StackEntry entry)
    {
        vm.RunRequested = (stackVm, type) =>
        {
            _ = type switch
            {
                StackRunType.Init  => RunInitAsync(stackVm),
                StackRunType.Apply => RunApplyAsync(stackVm),
                _                  => RunImportAsync(stackVm),
            };
        };

        vm.RemoveRequested = _ =>
        {
            _repo.Delete(entry.Id);
            Application.Current.Dispatcher.Invoke(() => Stacks.Remove(vm));
        };

        vm.EnvVarSaveRequested = async vars =>
        {
            entry.EnvVars = vars.ToList();
            // Persist encrypted values to secure DB
            await _envVarRepo.UpsertBatchAsync(entry.Name, vars);
            // Also update variables.tf (no sensitive values — declarations only)
            await EnvVarExtractor.WriteVariablesTfAsync(entry.ProjectPath, vars);
            _repo.Save(entry);
        };

        vm.DriftCheckRequested = stackVm => _ = RunDriftCheckAsync(stackVm);
        vm.DriftFixRequested   = stackVm => _ = RunDriftFixAsync(stackVm);

        vm.DriftIntervalChanged = stackVm =>
        {
            entry.DriftInterval = stackVm.DriftInterval;
            _repo.Save(entry);
        };

        vm.DriftAcknowledgeChanged = stackVm =>
        {
            entry.DriftAcknowledged = stackVm.DriftAcknowledged;
            _repo.Save(entry);
        };

        vm.AutoFixOnDriftChanged = stackVm =>
        {
            entry.AutoFixOnDrift = stackVm.AutoFixOnDrift;
            _repo.Save(entry);
        };

        vm.CronEntriesChanged = stackVm =>
        {
            entry.DriftCronExpressions = [.. stackVm.CronEntries.Select(c => c.Expression)];
            _repo.Save(entry);
        };
    }

    // ── Full Import pipeline (wizard) — unified single run ───────────────────

    public async Task BeginImportAsync(string name, string projectPath)
    {
        Directory.CreateDirectory(projectPath);
        CleanGeneratedTfFiles(projectPath);

        var stack = new StackEntry
        {
            Name        = name,
            ProjectPath = projectPath,
            Status      = StackStatus.Running,
        };
        _repo.Save(stack);

        var stackVm = new StackEntryViewModel(stack);
        WireRunRequested(stackVm, stack);
        Stacks.Insert(0, stackVm);
        stackVm.IsExpanded = true;

        var config = new TerraformProjectConfig { Name = name, RootPath = projectPath };
        _projectManager.SaveProject(config);

        var account     = _accounts.ActiveAccount;
        var region      = account?.DefaultRegion ?? "us-east-1";
        var creds       = BuildTfCredentials(account, region);
        var trigger     = "started by Import from AWS wizard";
        var generatedTf = Path.Combine(projectPath, "generated_resources.tf");
        var importsTf   = Path.Combine(projectPath, "imports.tf");
        int resourceCount = 0;

        await RunStepAsync(stackVm, stack, StackRunType.Import, trigger,
            async (vm, progress) =>
            {
                // ── Init ─────────────────────────────────────────────────────
                vm.AppendOutput("━━━ Init ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                string? stateBucket = null;
                vm.AppendOutput("▶ Ensuring S3 remote state bucket…");
                try
                {
                    stateBucket = await _importer.EnsureStateBucketAsync(region, progress);
                    vm.AppendOutput($"  ✔ state bucket: {stateBucket}");
                }
                catch (Exception ex)
                {
                    vm.AppendOutput($"  ⚠ Could not create state bucket: {ex.Message}");
                    vm.AppendOutput("    Falling back to local state.");
                }

                var stateKey = $"stacks/{name}/terraform.tfstate";
                await WriteProviderTfAsync(projectPath, region, stateBucket, stateKey);
                vm.AppendOutput("  ✔ provider.tf written");

                vm.AppendOutput($"\n▶ terraform init  dir={projectPath}");
                var initR = await _cli.InitAsync(projectPath, upgrade: false,
                    credentials: creds, progress: null);   // quiet — summary line below
                if (!initR.IsSuccess)
                {
                    vm.AppendOutput(initR.FullOutput);
                    vm.AppendOutput("\n✗ Init failed — aborting.");
                    return false;
                }
                vm.AppendOutput("  ✔ Terraform initialized.");

                // ── Import ────────────────────────────────────────────────────
                vm.AppendOutput("\n━━━ Import ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                var selected = await DiscoverAndSelectAsync(vm, region, progress);
                if (selected is null) return null;          // user cancelled the selection
                if (selected.Count == 0)
                {
                    vm.AppendOutput("\n✗ No resources found to import.");
                    return false;
                }
                resourceCount = selected.Count;

                vm.AppendOutput("\n▶ Writing imports.tf…");
                var importsContent = await _importer.GenerateImportBlocksAsync(selected);
                await File.WriteAllTextAsync(importsTf, importsContent);
                vm.AppendOutput($"  ✔ imports.tf  ({resourceCount} import blocks)");

                vm.AppendOutput("\n▶ Generating HCL resource files…");
                var suggestions = await _importer.SuggestHclFromExistingResourcesAsync(
                    selected, outputDir: projectPath);
                var written = suggestions.Count(s => s.HclResult.WasWritten);
                vm.AppendOutput($"  ✔ {written} .tf file(s) written");

                vm.AppendOutput("\n▶ terraform plan -generate-config-out=generated_resources.tf");
                vm.AppendOutput("  Generating HCL for remaining resource types…\n");
                var planGenR = await _cli.PlanWithGenerateConfigAsync(
                    projectPath, generatedTf, credentials: creds,
                    progress: MakePlanProgress(vm, resourceCount));

                if (File.Exists(generatedTf))
                {
                    var lineCount = (await File.ReadAllLinesAsync(generatedTf)).Length;
                    vm.AppendOutput($"\n✔ generated_resources.tf  ({lineCount} lines)");
                    if (!planGenR.IsSuccess && planGenR.ParsedErrors.Count > 0)
                        vm.AppendOutput($"  ⚠ {planGenR.ParsedErrors.Count} schema error(s) — correcting below.");
                }
                else if (written > 0)
                {
                    vm.AppendOutput($"\n✔ All resources covered by Atlas templates — no generation needed.");
                }
                else
                {
                    vm.AppendOutput($"\n✗ HCL generation failed: {planGenR.DiagnosticMessage}");
                    return false;
                }

                // ── Fix (inline — no separate run entry) ──────────────────────
                var fixes = await GeneratedHclFixer.FixAsync(generatedTf);
                if (fixes.TotalFixes > 0)
                {
                    vm.AppendOutput($"\n▶ Corrected {fixes.TotalFixes} schema issue(s):");
                    foreach (var line in fixes.ToLines())
                        vm.AppendOutput(line);
                }

                var envVars = await EnvVarExtractor.ExtractAndReplaceAsync(projectPath);
                if (envVars.Count > 0)
                {
                    stack.EnvVars = envVars.ToList();
                    await _envVarRepo.UpsertBatchAsync(stack.Name, envVars);
                    stackVm.LoadEnvVars(stack.EnvVars);
                    vm.AppendOutput($"\n▶ {envVars.Count} env var(s) extracted → stored encrypted:");
                    foreach (var v in envVars)
                        vm.AppendOutput($"    • {v.EnvKey} → var.{v.TfVarName}  [{v.ResourceName}]");
                }

                // ── Plan ──────────────────────────────────────────────────────
                vm.AppendOutput("\n━━━ Plan ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                vm.AppendOutput("▶ terraform plan  (validating corrected HCL)…\n");

                var tfVars = await _envVarRepo.GetTfVarsAsync(stack.Name);
                var planR  = await _cli.PlanAsync(
                    projectPath, credentials: creds,
                    tfVars: tfVars.Count > 0 ? tfVars : null,
                    progress: MakePlanProgress(vm, resourceCount));

                if (!planR.IsSuccess && planR.ParsedErrors.Count > 0)
                {
                    var skipped = await PruneSchemaErrorsAsync(planR.ParsedErrors, generatedTf, importsTf);
                    if (skipped.Count > 0)
                    {
                        vm.AppendOutput($"\n⚠ {skipped.Count} resource(s) removed — need manual management:");
                        foreach (var addr in skipped)
                            vm.AppendOutput($"    • {addr}");
                        vm.AppendOutput("\n  Retrying plan…\n");
                        planR = await _cli.PlanAsync(
                            projectPath, credentials: creds,
                            tfVars: tfVars.Count > 0 ? tfVars : null,
                            progress: MakePlanProgress(vm, resourceCount));
                    }
                }

                if (!planR.IsSuccess && planR.Status != TerraformResultStatus.PlanHasChanges)
                {
                    if (!string.IsNullOrWhiteSpace(planR.Stderr))
                        vm.AppendOutput(planR.Stderr.TrimEnd());
                    vm.AppendOutput($"\n✗ {planR.DiagnosticMessage}");
                }

                var ok = planR.Status == TerraformResultStatus.PlanHasChanges || planR.IsSuccess;
                if (ok)
                {
                    var split = await GeneratedHclSplitter.SplitAsync(generatedTf);
                    if (split.Count > 0)
                    {
                        vm.AppendOutput("\n▶ Organizing generated HCL by service:");
                        foreach (var (file, count) in split)
                            vm.AppendOutput($"    • {file}  ({count} resource(s))");
                    }

                    vm.AppendOutput($"\n  {resourceCount} resources ready — use Actions → Apply to import into state.");
                    stackVm.UpdateStatus(StackStatus.Ready);
                }
                return ok;
            });

        stackVm.NotifyRunCountChanged();
        _repo.Save(stack);
    }

    // ── Manual Init ───────────────────────────────────────────────────────────

    private async Task RunInitAsync(StackEntryViewModel stackVm)
    {
        var stack = _repo.GetAll().FirstOrDefault(s => s.Name == stackVm.Name);
        if (stack is null) return;

        stackVm.UpdateStatus(StackStatus.Running);
        stackVm.IsExpanded = true;

        var account = _accounts.ActiveAccount;
        var region  = account?.DefaultRegion ?? "us-east-1";
        var creds   = BuildTfCredentials(account, region);

        await RunStepAsync(stackVm, stack, StackRunType.Init, "started manually",
            async (vm, progress) =>
            {
                string? bucket = null;
                try { bucket = await _importer.EnsureStateBucketAsync(region, progress); }
                catch (Exception ex) { vm.AppendOutput($"  ⚠ State bucket: {ex.Message}"); }

                var stateKey = $"stacks/{stack.Name}/terraform.tfstate";
                await WriteProviderTfAsync(stack.ProjectPath, region, bucket, stateKey);
                vm.AppendOutput("  ✔ provider.tf updated");

                vm.AppendOutput($"▶ terraform init  dir={stack.ProjectPath}");
                var r = await _cli.InitAsync(stack.ProjectPath, upgrade: false,
                    credentials: creds, progress: null);   // quiet — summary line below
                if (r.IsSuccess)
                {
                    vm.AppendOutput("  ✔ Terraform initialized.");
                    stackVm.UpdateStatus(StackStatus.Ready);
                }
                else
                {
                    vm.AppendOutput(r.FullOutput);
                }
                return r.IsSuccess;
            });

        stackVm.NotifyRunCountChanged();
        _repo.Save(stack);
    }

    // ── Manual Import (full pipeline — unified single run) ────────────────────

    private async Task RunImportAsync(StackEntryViewModel stackVm)
    {
        var stack = _repo.GetAll().FirstOrDefault(s => s.Name == stackVm.Name);
        if (stack is null) return;

        stackVm.UpdateStatus(StackStatus.Running);
        stackVm.IsExpanded = true;

        var account     = _accounts.ActiveAccount;
        var region      = account?.DefaultRegion ?? "us-east-1";
        var creds       = BuildTfCredentials(account, region);
        var trigger     = "started manually";
        var generatedTf = Path.Combine(stack.ProjectPath, "generated_resources.tf");
        var importsTf   = Path.Combine(stack.ProjectPath, "imports.tf");
        int resourceCount = 0;

        await RunStepAsync(stackVm, stack, StackRunType.Import, trigger,
            async (vm, progress) =>
            {
                // ── Clean stale generated files ───────────────────────────────
                CleanGeneratedTfFiles(stack.ProjectPath);

                // ── Import ────────────────────────────────────────────────────
                var selected = await DiscoverAndSelectAsync(vm, region, progress);
                if (selected is null) return null;          // user cancelled the selection
                if (selected.Count == 0)
                {
                    vm.AppendOutput("\n✗ No resources found to import.");
                    return false;
                }
                resourceCount = selected.Count;

                vm.AppendOutput("\n▶ Writing imports.tf…");
                var importsContent = await _importer.GenerateImportBlocksAsync(selected);
                await File.WriteAllTextAsync(importsTf, importsContent);
                vm.AppendOutput($"  ✔ imports.tf  ({resourceCount} import blocks)");

                vm.AppendOutput("\n▶ Generating HCL resource files…");
                var suggestions = await _importer.SuggestHclFromExistingResourcesAsync(
                    selected, outputDir: stack.ProjectPath);
                var written = suggestions.Count(s => s.HclResult.WasWritten);
                vm.AppendOutput($"  ✔ {written} .tf file(s) written");

                vm.AppendOutput("\n▶ terraform plan -generate-config-out=generated_resources.tf");
                vm.AppendOutput("  Generating HCL for remaining resource types…\n");
                var planGenR = await _cli.PlanWithGenerateConfigAsync(
                    stack.ProjectPath, generatedTf, credentials: creds,
                    progress: MakePlanProgress(vm, resourceCount));

                if (File.Exists(generatedTf))
                {
                    var lineCount = (await File.ReadAllLinesAsync(generatedTf)).Length;
                    vm.AppendOutput($"\n✔ generated_resources.tf  ({lineCount} lines)");
                }
                else if (written > 0)
                {
                    vm.AppendOutput($"\n✔ All resources covered by Atlas templates — no generation needed.");
                }
                else
                {
                    vm.AppendOutput($"\n✗ HCL generation failed: {planGenR.DiagnosticMessage}");
                    return false;
                }

                // ── Fix (inline) ───────────────────────────────────────────────
                var fixes = await GeneratedHclFixer.FixAsync(generatedTf);
                if (fixes.TotalFixes > 0)
                {
                    vm.AppendOutput($"\n▶ Corrected {fixes.TotalFixes} schema issue(s):");
                    foreach (var line in fixes.ToLines())
                        vm.AppendOutput(line);
                }

                var envVars = await EnvVarExtractor.ExtractAndReplaceAsync(stack.ProjectPath);
                if (envVars.Count > 0)
                {
                    stack.EnvVars = envVars.ToList();
                    await _envVarRepo.UpsertBatchAsync(stack.Name, envVars);
                    stackVm.LoadEnvVars(stack.EnvVars);
                    vm.AppendOutput($"\n▶ {envVars.Count} env var(s) extracted → stored encrypted:");
                    foreach (var v in envVars)
                        vm.AppendOutput($"    • {v.EnvKey} → var.{v.TfVarName}  [{v.ResourceName}]");
                }

                // ── Plan ──────────────────────────────────────────────────────
                vm.AppendOutput("\n▶ terraform plan  (validating corrected HCL)…\n");
                var tfVars = await _envVarRepo.GetTfVarsAsync(stack.Name);
                var planR  = await _cli.PlanAsync(
                    stack.ProjectPath, credentials: creds,
                    tfVars: tfVars.Count > 0 ? tfVars : null,
                    progress: MakePlanProgress(vm, resourceCount));

                if (!planR.IsSuccess && planR.ParsedErrors.Count > 0)
                {
                    var skipped = await PruneSchemaErrorsAsync(planR.ParsedErrors, generatedTf, importsTf);
                    if (skipped.Count > 0)
                    {
                        vm.AppendOutput($"\n⚠ {skipped.Count} resource(s) removed — need manual management:");
                        foreach (var addr in skipped)
                            vm.AppendOutput($"    • {addr}");
                        vm.AppendOutput("\n  Retrying plan…\n");
                        planR = await _cli.PlanAsync(
                            stack.ProjectPath, credentials: creds,
                            tfVars: tfVars.Count > 0 ? tfVars : null,
                            progress: MakePlanProgress(vm, resourceCount));
                    }
                }

                if (!planR.IsSuccess && planR.Status != TerraformResultStatus.PlanHasChanges)
                {
                    if (!string.IsNullOrWhiteSpace(planR.Stderr))
                        vm.AppendOutput(planR.Stderr.TrimEnd());
                    vm.AppendOutput($"\n✗ {planR.DiagnosticMessage}");
                }

                var ok = planR.Status == TerraformResultStatus.PlanHasChanges || planR.IsSuccess;
                if (ok)
                {
                    var split = await GeneratedHclSplitter.SplitAsync(generatedTf);
                    if (split.Count > 0)
                    {
                        vm.AppendOutput("\n▶ Organizing generated HCL by service:");
                        foreach (var (file, count) in split)
                            vm.AppendOutput($"    • {file}  ({count} resource(s))");
                    }

                    vm.AppendOutput($"\n  {resourceCount} resources ready — use Actions → Apply to import into state.");
                    stackVm.UpdateStatus(StackStatus.Ready);
                }
                return ok;
            });

        stackVm.NotifyRunCountChanged();
        _repo.Save(stack);
    }

    // ── Manual Apply ──────────────────────────────────────────────────────────

    private async Task RunApplyAsync(StackEntryViewModel stackVm)
    {
        var stack = _repo.GetAll().FirstOrDefault(s => s.Name == stackVm.Name);
        if (stack is null) return;

        stackVm.UpdateStatus(StackStatus.Running);
        stackVm.IsExpanded = true;

        var account = _accounts.ActiveAccount;
        var region  = account?.DefaultRegion ?? "us-east-1";
        var creds   = BuildTfCredentials(account, region);

        await RunStepAsync(stackVm, stack, StackRunType.Apply, "started manually",
            async (vm, progress) =>
            {
                vm.AppendOutput("▶ terraform apply -auto-approve");
                var tfVars = await _envVarRepo.GetTfVarsAsync(stack.Name);
                var r = await _cli.ApplyAsync(stack.ProjectPath, planFile: null,
                    credentials: creds,
                    tfVars: tfVars.Count > 0 ? tfVars : null,
                    progress: progress);
                vm.AppendOutput(r.FullOutput);
                if (r.IsSuccess)
                {
                    vm.AppendOutput("\n✔ Apply complete — resources imported into state.");
                    stackVm.UpdateStatus(StackStatus.Ready);
                }
                return r.IsSuccess;
            });

        stackVm.NotifyRunCountChanged();
        _repo.Save(stack);
    }

    // ── Shared helpers ────────────────────────────────────────────────────────

    /// <summary>
    /// Discovery + user-selection step shared by both import pipelines:
    /// scans the whole account, lists everything found in the run output, then
    /// shows the category-grouped checkbox screen so the user picks exactly
    /// which resources get imported.
    /// Returns the selected resources, an empty list when nothing was discovered,
    /// or null when the user cancelled the dialog.
    /// </summary>
    private async Task<IReadOnlyList<DiscoveredResource>?> DiscoverAndSelectAsync(
        StackRunViewModel  vm,
        string             region,
        IProgress<string>  progress)
    {
        vm.AppendOutput($"▶ Discovering all AWS resources in {region}…");
        var options = new ImportOptions
        {
            Region                     = region,
            MaxResourcesPerType        = 500,
            IncludeTerminated          = false,
            IncludeAwsManagedResources = false,
            ResourceTypes              = Enum.GetValues<AwsResourceType>(),
        };

        // Compact discovery log: drop the per-service "Discovering…" start lines
        // and the "0 found" results — only services that returned something show up.
        var discoveryProgress = new Progress<string>(msg =>
        {
            if (msg.Contains("] Discovering", StringComparison.Ordinal)) return;
            if (Regex.IsMatch(msg, @"^\[\w+\]\s+0\s")) return;
            progress.Report(msg);
        });

        var analysis = await _importer.DiscoverResourcesAsync(options, discoveryProgress);
        vm.AppendOutput($"\n✔ Found {analysis.TotalDiscovered} resource(s) across {analysis.CountByType.Count} service type(s).");

        if (analysis.PartialErrors.Any())
        {
            vm.AppendOutput("\n  Partial errors (non-fatal):");
            foreach (var (t, e) in analysis.PartialErrors)
                vm.AppendOutput($"  ⚠ {t}: {e}");
        }

        if (analysis.TotalDiscovered == 0)
            return [];

        // ── User selection (checkbox screen) ───────────────────────────────
        vm.AppendOutput("\n▶ Waiting for resource selection…");
        IReadOnlyList<DiscoveredResource>? selected = null;
        Application.Current.Dispatcher.Invoke(() =>
            selected = _dialog.ShowImportSelectionDialog(analysis.Resources));

        if (selected is null)
        {
            vm.AppendOutput("  Cancelled — no resources were imported.");
            return null;
        }

        vm.AppendOutput($"  ✔ {selected.Count} of {analysis.TotalDiscovered} resource(s) selected for import.");
        int deselected = analysis.TotalDiscovered - selected.Count;
        if (deselected > 0)
            vm.AppendOutput($"    ({deselected} deselected — left unmanaged)");

        return selected;
    }

    /// <summary>
    /// Filtered IProgress for terraform plan output — keeps the panel readable even for
    /// large accounts with hundreds of resources:
    ///
    ///   • "Refreshing state..." / "Reading..." lines  → compact counter (1 line / 25 resources)
    ///   • "Still refreshing/reading" / "complete" noise → dropped
    ///   • Import blocks (will be imported)            → first 5, then 1 line / 25
    ///   • Create blocks (will be created)             → first 5, then 1 line / 25
    ///                                                    (attribute dump skipped — these are
    ///                                                    Atlas-generated sub-resources, not drift)
    ///   • Change blocks (will be updated / destroyed / replaced) → full diff verbatim
    ///                                                    (unexpected drift — user must review)
    ///   • Errors/warnings (╷│╵ diagnostic blocks)    → shown verbatim
    ///   • Plan summary / section headers              → shown verbatim
    ///   • Everything else                             → dropped
    /// </summary>
    private static IProgress<string> MakePlanProgress(StackRunViewModel vm, int totalResources)
    {
        // State machine: tracks which kind of resource block we're currently inside
        bool inImportBlock = false;   // inside "will be imported" → skip attribute dump
        bool inCreateBlock = false;   // inside "will be created"  → skip attribute dump (compact)
        bool inChangeBlock = false;   // inside update/destroy/replace → show full diff
        int  importCount   = 0;
        int  createCount   = 0;
        int  refreshCount  = 0;

        return new Progress<string>(raw =>
        {
            if (raw == null) return;
            var t = raw.TrimStart();

            // ── 1. Terraform diagnostic blocks (errors / warnings) ─────────────
            if (t.StartsWith("╷") || t.StartsWith("│") || t.StartsWith("╵"))
            {
                vm.AppendOutput(raw);
                return;
            }

            // ── 2. Resource refresh / read phase → compact running counter ─────
            if (t.Contains(": Refreshing state...", StringComparison.Ordinal) ||
                t.Contains(": Reading...",          StringComparison.Ordinal))
            {
                refreshCount++;
                if (refreshCount == 1)
                    vm.AppendOutput("  Refreshing state…");
                else if (refreshCount % 25 == 0)
                    vm.AppendOutput($"  Refreshing state… ({refreshCount} resources)");
                return;
            }

            // Per-resource noise — dropped entirely
            if (t.Contains(": Still refreshing...",    StringComparison.Ordinal) ||
                t.Contains(": Still reading...",       StringComparison.Ordinal) ||
                t.Contains(": Read complete after",    StringComparison.Ordinal) ||
                t.Contains(": Creation complete",      StringComparison.Ordinal) ||
                t.Contains(": Modifications complete", StringComparison.Ordinal))
                return;

            // ── 3. Plan/section headers ───────────────────────────────────────
            if (t.StartsWith("Plan:",            StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("No changes.",      StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("Changes to Outputs",StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("Note:",            StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("You can apply",    StringComparison.OrdinalIgnoreCase) ||
                (t.StartsWith("Terraform", StringComparison.OrdinalIgnoreCase) && t.Contains("will perform")) ||
                (t.StartsWith("OpenTofu",  StringComparison.OrdinalIgnoreCase) && t.Contains("will perform")) ||
                t.StartsWith("Terraform used",   StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("OpenTofu used",    StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("Resource actions are", StringComparison.OrdinalIgnoreCase) ||
                t.StartsWith("─────", StringComparison.Ordinal))
            {
                vm.AppendOutput(raw);
                return;
            }

            // ── 4. Resource action header: "  # type.name will be X" ──────────
            if (t.StartsWith("# "))
            {
                // Reset all block states on every new resource header
                inImportBlock = false;
                inCreateBlock = false;
                inChangeBlock = false;

                var willIdx = t.IndexOf(" will be", StringComparison.Ordinal);
                var addr    = willIdx > 2 ? t[2..willIdx].Trim() : t[2..].Trim();

                if (t.Contains("will be imported", StringComparison.OrdinalIgnoreCase))
                {
                    inImportBlock = true;
                    importCount++;

                    // Show first 5, then every 25, then the last one
                    bool show = importCount <= 5
                             || importCount % 25 == 0
                             || importCount == totalResources;
                    if (show)
                        vm.AppendOutput($"  {addr}: Importing... ({importCount}/{totalResources})");
                }
                else if (t.Contains("will be created", StringComparison.OrdinalIgnoreCase))
                {
                    // "will be created" blocks come from Atlas-generated sub-resources
                    // (e.g. aws_s3_bucket_public_access_block, aws_s3_bucket_server_side_
                    // encryption_configuration). Showing their full attribute diff for
                    // 90+ resources floods the panel with 1 800+ lines and triggers the
                    // MaxDisplayLines trim. Throttled one-liner instead.
                    inCreateBlock = true;
                    createCount++;
                    if (createCount <= 5 || createCount % 25 == 0)
                        vm.AppendOutput($"  + {addr}: Creating... ({createCount})");
                }
                else if (t.Contains("will be updated",   StringComparison.OrdinalIgnoreCase) ||
                         t.Contains("will be destroyed", StringComparison.OrdinalIgnoreCase) ||
                         t.Contains("must be replaced",  StringComparison.OrdinalIgnoreCase) ||
                         t.Contains("will be read",      StringComparison.OrdinalIgnoreCase))
                {
                    // Unexpected drift — always show the full diff so the user can review
                    inChangeBlock = true;
                    vm.AppendOutput(raw);
                }

                return;
            }

            // ── 5. Inside an update/destroy/replace block → show diff verbatim ──
            if (inChangeBlock)
            {
                vm.AppendOutput(raw);
                return;
            }

            // ── 6. Inside an import block → skip the attribute dump ─────────────
            // (thousands of "key = value" lines generated by -generate-config-out)
            if (inImportBlock) return;

            // ── 6b. Inside a create block → skip attribute dump (compact mode) ──
            // The one-liner was already emitted at the header (rule 4 above).
            if (inCreateBlock) return;

            // ── 7. Symbol-prefixed change lines outside explicit blocks ────────
            if (t.StartsWith("~ ") || t.StartsWith("+ ") || t.StartsWith("- ") ||
                t.StartsWith("<= "))
            {
                vm.AppendOutput(raw);
                return;
            }

            // Everything else: skip silently.
        });
    }

    /// <summary>
    /// Executes one pipeline step: creates the run, streams output, marks success/fail.
    /// The body returns true (success), false (failure) or null (cancelled by user).
    /// Returns false when the step did not succeed (caller should abort the pipeline).
    /// </summary>
    private async Task<bool> RunStepAsync(
        StackEntryViewModel                             stackVm,
        StackEntry                                      stack,
        StackRunType                                    type,
        string                                          trigger,
        Func<StackRunViewModel, IProgress<string>, Task<bool?>> body)
    {
        var run = new StackRun { StackId = stack.Id, Type = type, TriggerLabel = trigger };
        var vm  = stackVm.AddRun(run);
        vm.IsExpanded = true; // auto-show logs when run starts

        var progress = new Progress<string>(msg =>
            Application.Current.Dispatcher.Invoke(() => vm.AppendOutput(msg)));

        bool? ok;
        try
        {
            ok = await body(vm, progress);
        }
        catch (Exception ex)
        {
            vm.AppendOutput($"\nError: {ex.Message}");
            ok = false;
        }

        vm.Complete(ok switch
        {
            true  => StackRunStatus.Success,
            false => StackRunStatus.Failed,
            null  => StackRunStatus.Cancelled,
        });

        if (ok == false)     stackVm.UpdateStatus(StackStatus.Failed);
        else if (ok is null) stackVm.UpdateStatus(StackStatus.Ready);

        stackVm.NotifyRunCountChanged();
        _repo.Save(stack);
        return ok == true;
    }

    /// <summary>
    /// Deletes all Terraform-generated .tf files in the project directory
    /// (everything except provider.tf) so a re-import always starts clean.
    /// </summary>
    private static void CleanGeneratedTfFiles(string projectPath)
    {
        var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "provider.tf" };
        foreach (var file in Directory.GetFiles(projectPath, "*.tf"))
        {
            if (!keep.Contains(Path.GetFileName(file)))
                File.Delete(file);
        }
    }

    /// <summary>
    /// Writes provider.tf with the AWS provider + optional S3 remote backend.
    /// Credentials are NOT written to disk — injected as env vars by TerraformCliWrapper.
    /// </summary>
    private static Task WriteProviderTfAsync(
        string  projectPath,
        string  region,
        string? stateBucket = null,
        string? stateKey    = null)
    {
        var backendBlock = stateBucket is not null
            ? $$"""

              backend "s3" {
                bucket = "{{stateBucket}}"
                key    = "{{stateKey ?? "terraform.tfstate"}}"
                region = "{{region}}"
              }
            """
            : string.Empty;

        var content = $$"""
            # Generated by Atlas — do not edit manually.
            terraform {
              required_providers {
                aws = {
                  source  = "hashicorp/aws"
                  version = "~> 5.0"
                }
              }{{backendBlock}}
            }

            provider "aws" {
              region = "{{region}}"
              # Credentials are injected via env vars by Atlas (never stored on disk).
            }
            """;

        return File.WriteAllTextAsync(Path.Combine(projectPath, "provider.tf"), content);
    }


    /// <summary>
    /// Parses terraform error blocks to find which resources in generated_resources.tf
    /// failed schema validation, removes those resource blocks from generated_resources.tf
    /// and the corresponding import blocks from imports.tf.
    /// Returns the list of removed resource addresses.
    /// </summary>
    private static async Task<IReadOnlyList<string>> PruneSchemaErrorsAsync(
        IReadOnlyList<string> parsedErrors,
        string                generatedTfPath,
        string                importsTfPath)
    {
        // Extract "type.name" from lines like "  with aws_lambda_function.getclientid,"
        // but only for errors that reference generated_resources.tf (not hand-crafted files).
        var addrRx = new Regex(
            @"with\s+([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)[\s,]",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);

        var failing = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var err in parsedErrors)
        {
            if (!err.Contains("generated_resources.tf", StringComparison.OrdinalIgnoreCase))
                continue;
            var m = addrRx.Match(err);
            if (m.Success)
                failing.Add(m.Groups[1].Value);
        }

        if (failing.Count == 0) return [];

        if (File.Exists(generatedTfPath))
        {
            var content = await File.ReadAllTextAsync(generatedTfPath, Encoding.UTF8);
            content     = RemoveGeneratedResourceBlocks(content, failing);
            await File.WriteAllTextAsync(generatedTfPath, content, Encoding.UTF8);
        }

        if (File.Exists(importsTfPath))
        {
            var content = await File.ReadAllTextAsync(importsTfPath, Encoding.UTF8);
            content     = RemoveImportBlocks(content, failing);
            await File.WriteAllTextAsync(importsTfPath, content, Encoding.UTF8);
        }

        return [.. failing];
    }

    /// <summary>
    /// Removes resource blocks (and their leading # __generated__ comment lines) from
    /// generated_resources.tf for the given resource addresses.
    /// Uses brace-counting to correctly span multi-line blocks with nested sub-blocks.
    /// </summary>
    private static string RemoveGeneratedResourceBlocks(
        string content, ISet<string> addresses)
    {
        var lines           = content.Split('\n');
        var output          = new List<string>(lines.Length);
        var pendingComments = new List<string>();

        bool inBlock   = false;
        bool dropBlock = false;
        int  depth     = 0;

        var resRx = new Regex(
            @"^resource\s+""([^""]+)""\s+""([^""]+)""",
            RegexOptions.Compiled);

        foreach (var line in lines)
        {
            var trimmed = line.TrimStart();

            if (!inBlock)
            {
                // Buffer leading __generated__ comment lines — they belong to the next resource
                if (trimmed.StartsWith("# __generated__ by"))
                {
                    pendingComments.Add(line);
                    continue;
                }

                var m = resRx.Match(trimmed);
                if (m.Success)
                {
                    var addr  = $"{m.Groups[1].Value}.{m.Groups[2].Value}";
                    dropBlock = addresses.Contains(addr);
                    inBlock   = true;
                    depth     = CountBraces(line);

                    if (!dropBlock)
                    {
                        output.AddRange(pendingComments);
                        output.Add(line);
                    }
                    pendingComments.Clear();
                    continue;
                }

                // Not a resource / not a comment — flush the buffer and keep the line
                output.AddRange(pendingComments);
                pendingComments.Clear();
                output.Add(line);
            }
            else
            {
                depth += CountBraces(line);
                if (!dropBlock) output.Add(line);

                if (depth <= 0)
                {
                    inBlock   = false;
                    dropBlock = false;
                    depth     = 0;
                }
            }
        }

        output.AddRange(pendingComments);
        return string.Join('\n', output);
    }

    /// <summary>
    /// Removes import { ... } blocks (and their preceding comment lines) from imports.tf
    /// for the given resource addresses.
    /// </summary>
    private static string RemoveImportBlocks(string content, ISet<string> addresses)
    {
        var lines  = content.Split('\n');
        var output = new List<string>(lines.Length);
        var buf    = new List<string>();   // accumulated comments + current import block
        bool inImport = false;
        bool skip     = false;

        foreach (var line in lines)
        {
            var trimmed = line.TrimStart();

            if (!inImport)
            {
                if (trimmed == "import {" || trimmed.StartsWith("import {"))
                {
                    buf.Add(line);
                    inImport = true;
                    skip     = false;
                }
                else if (trimmed.StartsWith("#") || string.IsNullOrWhiteSpace(trimmed))
                {
                    // May be a leading comment for the next import block
                    buf.Add(line);
                }
                else
                {
                    // Non-import line — flush buffer and emit
                    output.AddRange(buf);
                    buf.Clear();
                    output.Add(line);
                }
            }
            else
            {
                buf.Add(line);

                if (trimmed.StartsWith("to = "))
                {
                    var addr = trimmed["to = ".Length..].Trim();
                    if (addresses.Contains(addr)) skip = true;
                }

                if (trimmed == "}" || trimmed.StartsWith("}"))
                {
                    inImport = false;
                    if (!skip) output.AddRange(buf);
                    buf.Clear();
                    skip = false;
                }
            }
        }

        output.AddRange(buf);
        return string.Join('\n', output);
    }

    /// <summary>Counts net open braces on a line (ignores quoted strings).</summary>
    private static int CountBraces(string line)
    {
        int  count    = 0;
        bool inString = false;
        foreach (char c in line)
        {
            if (c == '"') inString = !inString;
            if (inString) continue;
            if (c == '{') count++;
            else if (c == '}') count--;
        }
        return count;
    }

    private TerraformAwsCredentials? BuildTfCredentials(AwsAccount? account, string region)
    {
        if (account is null) return null;
        var secret = _accounts.GetActiveSecretKey();
        return new TerraformAwsCredentials(account.AccessKeyId, secret, region);
    }

    // ── Drift Detection Monitor ───────────────────────────────────────────────

    private void StartDriftMonitor()
    {
        _driftTimer = new System.Timers.Timer(TimeSpan.FromMinutes(1).TotalMilliseconds)
        {
            AutoReset = true,
        };
        _driftTimer.Elapsed += (_, _) => _ = CheckOverdueStacksAsync();
        _driftTimer.Start();
    }

    private async Task CheckOverdueStacksAsync()
    {
        StackEntryViewModel[] due = [];
        Application.Current.Dispatcher.Invoke(() =>
            due = [.. Stacks.Where(vm => vm.IsDriftDue)]);

        foreach (var vm in due)
            await RunDriftCheckAsync(vm);
    }

    private async Task RunDriftCheckAsync(StackEntryViewModel stackVm)
    {
        var stack = _repo.GetAll().FirstOrDefault(s => s.Name == stackVm.Name);
        if (stack is null) return;

        Application.Current.Dispatcher.Invoke(() =>
            stackVm.DriftStatus = DriftStatus.Checking);

        var account = _accounts.ActiveAccount;
        var region  = account?.DefaultRegion ?? "us-east-1";
        var creds   = BuildTfCredentials(account, region);

        DriftStatus finalStatus;
        string?     summary    = null;
        string?     planOutput = null;

        try
        {
            var tfVars = await _envVarRepo.GetTfVarsAsync(stack.Name);
            var result = await _cli.PlanAsync(
                stack.ProjectPath,
                credentials: creds,
                tfVars: tfVars.Count > 0 ? tfVars : null);

            if (result.Status == TerraformResultStatus.NoChanges)
            {
                finalStatus = DriftStatus.Clean;
            }
            else if (result.Status == TerraformResultStatus.PlanHasChanges)
            {
                finalStatus = DriftStatus.Drifted;
                summary     = ParseDriftSummary(result.Stdout);
                planOutput  = ExtractDriftDiff(result.Stdout);
            }
            else
            {
                finalStatus = DriftStatus.Error;
                summary     = result.DiagnosticMessage;
            }
        }
        catch (Exception ex)
        {
            finalStatus = DriftStatus.Error;
            summary     = ex.Message;
        }

        stackVm.UpdateDriftResult(finalStatus, summary, planOutput, DateTime.UtcNow);

        // Persist result to disk
        stack.DriftStatus      = finalStatus;
        stack.DriftSummary     = summary;
        stack.DriftPlanOutput  = planOutput;
        stack.LastDriftCheckAt = DateTime.UtcNow;
        _repo.Save(stack);

        // Auto-fix: if configured, trigger apply immediately
        if (finalStatus == DriftStatus.Drifted && stackVm.AutoFixOnDrift)
            await RunDriftFixAsync(stackVm);
    }

    private async Task RunDriftFixAsync(StackEntryViewModel stackVm)
    {
        var stack = _repo.GetAll().FirstOrDefault(s => s.Name == stackVm.Name);
        if (stack is null) return;

        stackVm.UpdateStatus(StackStatus.Running);

        var account = _accounts.ActiveAccount;
        var region  = account?.DefaultRegion ?? "us-east-1";
        var creds   = BuildTfCredentials(account, region);

        await RunStepAsync(stackVm, stack, StackRunType.FixDrift, "started by Fix Drift",
            async (runVm, progress) =>
            {
                // ── Apply ────────────────────────────────────────────────────
                runVm.AppendOutput("━━━ Fix Drift ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                runVm.AppendOutput("▶ terraform apply -auto-approve\n");

                Application.Current.Dispatcher.Invoke(() =>
                    stackVm.DriftStatus = DriftStatus.Checking);

                var tfVars      = await _envVarRepo.GetTfVarsAsync(stack.Name);
                var applyResult = await _cli.ApplyAsync(
                    stack.ProjectPath,
                    planFile:    null,
                    credentials: creds,
                    tfVars:      tfVars.Count > 0 ? tfVars : null,
                    progress:    progress);

                runVm.AppendOutput(applyResult.FullOutput);

                if (!applyResult.IsSuccess)
                {
                    var msg = applyResult.DiagnosticMessage ?? "Apply failed";
                    stackVm.UpdateDriftResult(DriftStatus.Error, msg, null, DateTime.UtcNow);
                    stack.DriftStatus      = DriftStatus.Error;
                    stack.DriftSummary     = msg;
                    stack.DriftPlanOutput  = null;
                    stack.LastDriftCheckAt = DateTime.UtcNow;
                    return false;
                }

                runVm.AppendOutput("\n✔ Apply complete.");

                // ── Verify drift resolved ────────────────────────────────────
                runVm.AppendOutput("\n━━━ Verify ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
                runVm.AppendOutput("▶ terraform plan  (verifying drift resolved)…\n");

                var planResult = await _cli.PlanAsync(
                    stack.ProjectPath,
                    credentials: creds,
                    tfVars:      tfVars.Count > 0 ? tfVars : null,
                    progress:    progress);

                DriftStatus finalStatus;
                string?     summary    = null;
                string?     planOutput = null;

                if (planResult.Status == TerraformResultStatus.NoChanges)
                {
                    finalStatus = DriftStatus.Clean;
                    runVm.AppendOutput("\n✔ No drift — infrastructure matches Terraform configuration.");
                }
                else if (planResult.Status == TerraformResultStatus.PlanHasChanges)
                {
                    finalStatus = DriftStatus.Drifted;
                    summary     = ParseDriftSummary(planResult.Stdout);
                    planOutput  = ExtractDriftDiff(planResult.Stdout);
                    runVm.AppendOutput($"\n⚠ Drift still present: {summary ?? "see plan above"}");
                }
                else
                {
                    finalStatus = DriftStatus.Error;
                    summary     = planResult.DiagnosticMessage;
                    runVm.AppendOutput($"\n✗ Verify failed: {summary}");
                }

                stackVm.UpdateDriftResult(finalStatus, summary, planOutput, DateTime.UtcNow);
                stack.DriftStatus      = finalStatus;
                stack.DriftSummary     = summary;
                stack.DriftPlanOutput  = planOutput;
                stack.LastDriftCheckAt = DateTime.UtcNow;

                stackVm.UpdateStatus(StackStatus.Ready);
                return applyResult.IsSuccess;
            });
    }

    private static string? ExtractDriftDiff(string planOutput)
    {
        if (string.IsNullOrEmpty(planOutput)) return null;
        var lines  = planOutput.Split('\n');
        var sb     = new StringBuilder();
        bool inDiff = false;

        foreach (var line in lines)
        {
            var t = line.TrimStart();
            if (!inDiff && t.StartsWith("# "))
                inDiff = true;
            if (inDiff)
            {
                if (t.StartsWith("Plan:",       StringComparison.OrdinalIgnoreCase) ||
                    t.StartsWith("No changes.", StringComparison.OrdinalIgnoreCase))
                    break;
                sb.AppendLine(line);
            }
        }
        return sb.Length > 0 ? sb.ToString().TrimEnd() : null;
    }

    private static string? ParseDriftSummary(string planOutput)
    {
        var m = Regex.Match(planOutput, @"Plan:\s+(.+?)\.", RegexOptions.Multiline);
        if (!m.Success) return null;

        // Filter out zero-count parts: "0 to add, 3 to change, 0 to destroy" → "3 to change"
        var parts = m.Groups[1].Value
            .Split(',')
            .Select(p => p.Trim())
            .Where(p => !p.StartsWith("0 ", StringComparison.Ordinal))
            .ToList();

        return parts.Count > 0 ? string.Join(", ", parts) : m.Groups[1].Value.Trim();
    }
}
