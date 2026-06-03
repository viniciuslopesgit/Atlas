using System.Globalization;
using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Atlas.Models;
using Atlas.Services;
using Atlas.Services.AWS;
using Microsoft.Win32;

namespace Atlas.ViewModels;

// ── Calendar picker item ───────────────────────────────────────────────────────

/// <summary>One month cell in the visual date-range picker.</summary>
public sealed class PickerMonthItem : ObservableObject
{
    public required DateOnly  Date      { get; init; }
    public required string    Label     { get; init; }   // "Jan", "Feb", …
    public required bool      IsFuture  { get; init; }
    public required ICommand? SelectCmd { get; init; }   // bound to VM command

    private bool _isStart;
    private bool _isEnd;
    private bool _isInRange;

    public bool IsStart   { get => _isStart;   set => SetProperty(ref _isStart,   value); }
    public bool IsEnd     { get => _isEnd;      set => SetProperty(ref _isEnd,     value); }
    public bool IsInRange { get => _isInRange;  set => SetProperty(ref _isInRange, value); }

    public bool IsEnabled => !IsFuture;
}

// ── Chart / table view records ─────────────────────────────────────────────────

/// <summary>One coloured segment in a monthly stacked bar.</summary>
public sealed class BillingBarSegment
{
    public required string  Service  { get; init; }
    public required decimal Amount   { get; init; }
    public required double  HeightPx { get; init; }
    public required Brush   Fill     { get; init; }

    public string Tooltip => $"{Service}\n${Amount:N2}";
}

/// <summary>One month column in the stacked bar chart.</summary>
public sealed class BillingBar
{
    public required string                           MonthLabel { get; init; }
    public required decimal                          Total      { get; init; }
    public required IReadOnlyList<BillingBarSegment> Segments   { get; init; }
    public string TotalText => $"${Total:N2}";
}

/// <summary>One row in the service breakdown table.</summary>
public sealed class ServiceTotalRow
{
    public required string  Service  { get; init; }
    public required decimal Total    { get; init; }
    public required string  Currency { get; init; }
    public required double  Percent  { get; init; }
    public required Brush   Fill     { get; init; }

    public string TotalText   => $"{Currency} {Total:N2}";
    public string PercentText => $"{Percent:N1}%";
    public GridLength FillLength  => new(Math.Max(1,   Percent),       GridUnitType.Star);
    public GridLength EmptyLength => new(Math.Max(0, 100 - Percent),   GridUnitType.Star);
}

// ── ViewModel ──────────────────────────────────────────────────────────────────

public partial class BillingViewModel : AsyncViewModel
{
    private readonly IBillingService _billing;
    private readonly IAccountService _accounts;
    private readonly ILicenseService _license;

    // ── Service colour palette (8 distinct colours) ───────────────────────────
    private static readonly string[] Palette =
    [
        "#5C7CFA", "#F06595", "#51CF66", "#FF922B",
        "#CC5DE8", "#22B8CF", "#FCC419", "#A8A8B4"
    ];

    private static Brush MakeBrush(string hex)
    {
        var b = new SolidColorBrush((Color)ColorConverter.ConvertFromString(hex));
        b.Freeze();
        return b;
    }

    private static readonly Brush[] Brushes = [.. Palette.Select(MakeBrush)];

    // ── Stored event handlers (so they can be unsubscribed) ───────────────────
    private readonly EventHandler _licenseChangedHandler;

    // ── Date range state ──────────────────────────────────────────────────────
    [ObservableProperty] private DateOnly _startDate;
    [ObservableProperty] private DateOnly _endDate;

    // ── Calendar picker state ─────────────────────────────────────────────────
    [ObservableProperty] private bool    _isPickerOpen;
    [ObservableProperty] private int     _pickerLeftYear;
    [ObservableProperty] private DateOnly? _tempStart;
    [ObservableProperty] private DateOnly? _tempEnd;

    // ── Other observable state ────────────────────────────────────────────────
    [ObservableProperty] private BillingReport? _report;
    [ObservableProperty] private bool           _isPro;
    /// <summary>Soft amber notice shown when the selected range exceeds AWS's 14-month retention.</summary>
    [ObservableProperty] private string?        _dataLimitNotice;

    // ── Cached computed lists (rebuilt when Report changes) ───────────────────
    private List<BillingBar>      _billingBarsCache  = [];
    private List<ServiceTotalRow> _serviceTotalsCache = [];

    // ── Computed: year on the right panel ────────────────────────────────────
    public int PickerRightYear => PickerLeftYear + 1;

    // Automatically notify PickerRightYear whenever PickerLeftYear changes
    partial void OnPickerLeftYearChanged(int value) => OnPropertyChanged(nameof(PickerRightYear));

    // ── Computed: display text for the range button ───────────────────────────
    public string SelectedRangeText
    {
        get
        {
            if (StartDate == default || EndDate == default) return "Select period…";
            return $"{StartDate:MMM yyyy} – {EndDate:MMM yyyy}";
        }
    }

    // ── Computed: tentative text while user is picking ────────────────────────
    public string TempRangeText
    {
        get
        {
            if (TempStart == null) return "Click a month to set start";
            if (TempEnd   == null) return $"{TempStart.Value:MMM yyyy} → click end month";
            return $"{TempStart.Value:MMM yyyy} – {TempEnd.Value:MMM yyyy}";
        }
    }

    // ── Calendar month grids ──────────────────────────────────────────────────
    public List<PickerMonthItem> LeftYearMonths  => BuildPickerYear(PickerLeftYear);
    public List<PickerMonthItem> RightYearMonths => BuildPickerYear(PickerRightYear);

    // ── Other computed display properties ─────────────────────────────────────
    public bool HasData          => Report?.Entries.Count > 0;
    public bool HasActiveAccount => _accounts.ActiveAccount != null;

    public string TotalCostText
        => Report == null ? "—" : $"{Report.Currency} {Report.GrandTotal:N2}";

    public string AvgMonthlyCostText
    {
        get
        {
            if (Report == null || Report.MonthLabels.Count == 0) return "—";
            return $"{Report.Currency} {Report.GrandTotal / Report.MonthLabels.Count:N2}";
        }
    }

    public string MoMChangeText
    {
        get
        {
            if (Report == null || Report.MonthLabels.Count < 2) return string.Empty;
            var m    = Report.MonthLabels;
            var cur  = Report.Entries.Where(e => e.MonthLabel == m[^1]).Sum(e => e.Amount);
            var prev = Report.Entries.Where(e => e.MonthLabel == m[^2]).Sum(e => e.Amount);
            if (prev == 0) return string.Empty;
            var pct = (cur - prev) / prev * 100;
            return pct >= 0 ? $"▲ {pct:N1}% MoM" : $"▼ {Math.Abs(pct):N1}% MoM";
        }
    }

    public bool MoMUp
    {
        get
        {
            if (Report == null || Report.MonthLabels.Count < 2) return false;
            var m = Report.MonthLabels;
            return Report.Entries.Where(e => e.MonthLabel == m[^1]).Sum(e => e.Amount)
                 > Report.Entries.Where(e => e.MonthLabel == m[^2]).Sum(e => e.Amount);
        }
    }

    public string PeriodRangeText
    {
        get
        {
            if (Report == null || Report.MonthLabels.Count == 0) return string.Empty;
            return $"{Report.MonthLabels[0]} – {Report.MonthLabels[^1]}";
        }
    }

    // ── Chart & table data ────────────────────────────────────────────────────
    public List<BillingBar>      BillingBars   => _billingBarsCache;
    public List<ServiceTotalRow> ServiceTotals => _serviceTotalsCache;

    // ── Constructor ───────────────────────────────────────────────────────────
    public BillingViewModel(
        IBillingService billing,
        IAccountService accounts,
        ILicenseService license)
    {
        _billing  = billing;
        _accounts = accounts;
        _license  = license;

        _isPro = _license.IsPro;

        // Default range: last 6 months
        var today = DateOnly.FromDateTime(DateTime.Today);
        _endDate   = new DateOnly(today.Year, today.Month, 1);
        _startDate = _endDate.AddMonths(-5);

        // Picker opens showing the two most recent years
        _pickerLeftYear = today.Year - 1;

        // Store handler so it can be unsubscribed in Dispose()
        _licenseChangedHandler = (_, _) => IsPro = _license.IsPro;
        _license.ProStatusChanged      += _licenseChangedHandler;
        _accounts.ActiveAccountChanged += OnAccountChanged;
    }

    private void OnAccountChanged(object? s, EventArgs e)
    {
        OnPropertyChanged(nameof(HasActiveAccount));
        _ = LoadAsync(force: true);
    }

    // ── Commands ───────────────────────────────────────────────────────────────

    [RelayCommand]
    public async Task LoadAsync(bool force = false)
    {
        if (_accounts.ActiveAccount == null) return;
        if (!force && !IsDataStale) return;

        var ct = BeginLoad();
        try
        {
            DataLimitNotice = null;
            Report = await _billing.GetCostBreakdownAsync(StartDate, EndDate, ct: ct);
            NotifyAllProps();
            EndLoad();
        }
        catch (Exception ex) when (IsHistoricalDataError(ex))
        {
            // Keep the existing Report data visible — just surface a soft, actionable notice
            DataLimitNotice =
                "AWS Cost Explorer only stores 14 months of data by default. " +
                "Select a more recent date range, or enable extended retention in your " +
                "AWS Cost Explorer settings (Cost Management → Cost Explorer → Settings).";
            EndLoad();
        }
        catch (Exception ex)
        {
            DataLimitNotice = null;
            HandleError("BillingViewModel.LoadAsync", ex);
        }
    }

    private static bool IsHistoricalDataError(Exception ex) =>
        ex.Message.Contains("14 months",       StringComparison.OrdinalIgnoreCase) ||
        ex.Message.Contains("historical data", StringComparison.OrdinalIgnoreCase) ||
        ex.Message.Contains("DataUnavailable", StringComparison.OrdinalIgnoreCase);

    [RelayCommand]
    private void ResetDateRange()
    {
        var today = DateOnly.FromDateTime(DateTime.Today);
        EndDate   = new DateOnly(today.Year, today.Month, 1);
        StartDate = EndDate.AddMonths(-5);
        DataLimitNotice = null;
        OnPropertyChanged(nameof(SelectedRangeText));
        _ = LoadAsync(force: true);
    }

    // ── Picker commands ───────────────────────────────────────────────────────

    [RelayCommand]
    private void OpenPicker()
    {
        // Reset temp state & re-centre the calendar around the current selection
        TempStart = StartDate == default ? null : StartDate;
        TempEnd   = EndDate   == default ? null : EndDate;

        var today = DateOnly.FromDateTime(DateTime.Today);
        PickerLeftYear = (StartDate != default ? StartDate.Year : today.Year - 1);
        // Ensure right year doesn't go into the future
        if (PickerLeftYear + 1 > today.Year) PickerLeftYear = today.Year - 1;

        RefreshPickerMonths();
        IsPickerOpen = true;
        OnPropertyChanged(nameof(TempRangeText));
    }

    [RelayCommand]
    private void ClosePicker() => IsPickerOpen = false;

    [RelayCommand]
    private void PrevPickerYear()
    {
        PickerLeftYear--;   // OnPickerLeftYearChanged fires → PickerRightYear notified automatically
        RefreshPickerMonths();
    }

    [RelayCommand]
    private void NextPickerYear()
    {
        var today = DateOnly.FromDateTime(DateTime.Today);
        if (PickerRightYear >= today.Year) return;   // don't scroll into the future
        PickerLeftYear++;   // OnPickerLeftYearChanged fires → PickerRightYear notified automatically
        RefreshPickerMonths();
    }

    [RelayCommand]
    private void SelectMonth(DateOnly month)
    {
        if (TempStart == null || (TempStart != null && TempEnd != null))
        {
            // First click — set start
            TempStart = month;
            TempEnd   = null;
        }
        else
        {
            // Second click — set end (swap if needed)
            if (month < TempStart!.Value)
            {
                TempEnd   = TempStart;
                TempStart = month;
            }
            else
            {
                TempEnd = month;
            }
        }

        RefreshPickerHighlights();
        OnPropertyChanged(nameof(TempRangeText));
    }

    [RelayCommand]
    private void ApplyRange()
    {
        if (TempStart == null || TempEnd == null) return;

        StartDate = TempStart.Value;
        EndDate   = TempEnd.Value;

        IsPickerOpen = false;
        OnPropertyChanged(nameof(SelectedRangeText));
        _ = LoadAsync(force: true);
    }

    [RelayCommand]
    private void ApplyPreset(string preset)
    {
        var today = DateOnly.FromDateTime(DateTime.Today);
        var endM  = new DateOnly(today.Year, today.Month, 1);

        (TempStart, TempEnd) = preset switch
        {
            "3M"        => (endM.AddMonths(-2),  endM),
            "6M"        => (endM.AddMonths(-5),  endM),
            "12M"       => (endM.AddMonths(-11), endM),
            "24M"       => (endM.AddMonths(-23), endM),
            "ThisYear"  => (new DateOnly(today.Year, 1, 1), endM),
            "LastYear"  => (new DateOnly(today.Year - 1, 1, 1),
                            new DateOnly(today.Year - 1, 12, 1)),
            _           => (endM.AddMonths(-5), endM)
        };

        RefreshPickerHighlights();
        OnPropertyChanged(nameof(TempRangeText));
    }

    // ── Picker helpers ─────────────────────────────────────────────────────────

    private List<PickerMonthItem> BuildPickerYear(int year)
    {
        var today = DateOnly.FromDateTime(DateTime.Today);
        var items = new List<PickerMonthItem>(12);
        for (var m = 1; m <= 12; m++)
        {
            var d = new DateOnly(year, m, 1);
            items.Add(new PickerMonthItem
            {
                Date      = d,
                Label     = d.ToString("MMM", CultureInfo.InvariantCulture),
                IsFuture  = d > new DateOnly(today.Year, today.Month, 1),
                SelectCmd = SelectMonthCommand
            });
        }
        ApplyHighlightsTo(items);
        return items;
    }

    private void RefreshPickerMonths()
    {
        OnPropertyChanged(nameof(LeftYearMonths));
        OnPropertyChanged(nameof(RightYearMonths));
    }

    private void RefreshPickerHighlights()
    {
        OnPropertyChanged(nameof(LeftYearMonths));
        OnPropertyChanged(nameof(RightYearMonths));
    }

    private void ApplyHighlightsTo(IEnumerable<PickerMonthItem> items)
    {
        foreach (var item in items)
        {
            item.IsStart   = TempStart.HasValue && item.Date == TempStart.Value;
            item.IsEnd     = TempEnd.HasValue   && item.Date == TempEnd.Value;
            item.IsInRange = TempStart.HasValue && TempEnd.HasValue
                          && item.Date > TempStart.Value && item.Date < TempEnd.Value;
        }
    }

    // ── CSV export ────────────────────────────────────────────────────────────

    [RelayCommand]
    private async Task ExportCsvAsync()
    {
        if (Report == null) return;

        var dlg = new SaveFileDialog
        {
            Title      = "Export Billing Report as CSV",
            Filter     = "CSV files (*.csv)|*.csv|All files (*.*)|*.*",
            FileName   = $"Atlas_Billing_{DateTime.Now:yyyyMMdd_HHmm}.csv",
            DefaultExt = "csv"
        };
        if (dlg.ShowDialog() != true) return;

        var path         = dlg.FileName;
        var report       = Report;
        var rangeLabel   = SelectedRangeText;

        await Task.Run(() =>
        {
            using var w = new StreamWriter(path, false,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: true));

            w.WriteLine("Atlas — Billing Report");
            w.WriteLine($"Date Range,{rangeLabel}");
            w.WriteLine($"Period,{report.MonthLabels.FirstOrDefault()} to {report.MonthLabels.LastOrDefault()}");
            w.WriteLine($"Exported,{DateTime.Now:yyyy-MM-dd HH:mm:ss}");
            w.WriteLine($"Grand Total,{report.Currency} {report.GrandTotal:N2}");
            w.WriteLine();

            w.WriteLine("Monthly Breakdown");
            w.WriteLine("Month,Service / Group,Amount,Currency,% of Month Total");

            foreach (var month in report.MonthLabels)
            {
                var rows   = report.Entries
                    .Where(e => e.MonthLabel == month)
                    .OrderByDescending(e => e.Amount)
                    .ToList();
                var mTotal = rows.Sum(e => e.Amount);

                foreach (var row in rows)
                {
                    var pct = mTotal > 0 ? row.Amount / mTotal * 100 : 0;
                    w.WriteLine($"{Esc(row.MonthLabel)},{Esc(row.Service)}," +
                                $"{row.Amount.ToString("F2", CultureInfo.InvariantCulture)}," +
                                $"{row.Currency},{pct:F1}%");
                }
                w.WriteLine($"{Esc(month)},MONTH TOTAL," +
                            $"{mTotal.ToString("F2", CultureInfo.InvariantCulture)},USD,100.0%");
                w.WriteLine();
            }

            w.WriteLine("Service / Group Summary");
            w.WriteLine("Service / Group,Total Amount,Currency,% of Grand Total");
            foreach (var svc in report.TopServices)
            {
                var total = report.Entries.Where(e => e.Service == svc).Sum(e => e.Amount);
                var pct   = report.GrandTotal > 0 ? total / report.GrandTotal * 100 : 0;
                w.WriteLine($"{Esc(svc)},{total.ToString("F2", CultureInfo.InvariantCulture)},USD,{pct:F1}%");
            }
            w.WriteLine();
            w.WriteLine($"GRAND TOTAL,{report.GrandTotal.ToString("F2", CultureInfo.InvariantCulture)},USD,100.0%");
        });
    }

    [RelayCommand]
    private async Task RefreshAsync() => await LoadAsync(force: true);

    // ── Chart builders ────────────────────────────────────────────────────────

    private List<BillingBar> BuildBars()
    {
        if (Report == null || Report.MonthLabels.Count == 0) return [];

        const double maxBarPx = 200.0;

        var monthTotals = Report.MonthLabels.ToDictionary(
            m => m,
            m => Report.Entries.Where(e => e.MonthLabel == m).Sum(e => e.Amount));

        var globalMax = monthTotals.Values.DefaultIfEmpty(0).Max();
        if (globalMax == 0) return [];

        var bars = new List<BillingBar>();
        foreach (var month in Report.MonthLabels)
        {
            var monthTotal = monthTotals[month];
            var barH       = (double)monthTotal / (double)globalMax * maxBarPx;

            var segments = new List<BillingBarSegment>();
            for (var i = 0; i < Report.TopServices.Count; i++)
            {
                var svc    = Report.TopServices[i];
                var amount = Report.Entries
                    .FirstOrDefault(e => e.MonthLabel == month && e.Service == svc)?.Amount ?? 0m;
                if (amount < 0.001m) continue;

                var segH = monthTotal > 0 ? (double)amount / (double)monthTotal * barH : 0;
                segments.Add(new BillingBarSegment
                {
                    Service  = ShortName(svc),
                    Amount   = amount,
                    HeightPx = Math.Max(1.0, segH),
                    Fill     = Brushes[i % Brushes.Length]
                });
            }
            segments.Reverse();   // WPF StackPanel top→bottom, biggest at bottom

            bars.Add(new BillingBar
            {
                MonthLabel = month,
                Total      = monthTotal,
                Segments   = segments
            });
        }
        return bars;
    }

    private List<ServiceTotalRow> BuildTotals()
    {
        if (Report == null) return [];

        return Report.TopServices
            .Select((svc, i) =>
            {
                var total = Report.Entries.Where(e => e.Service == svc).Sum(e => e.Amount);
                var pct   = Report.GrandTotal > 0
                    ? (double)(total / Report.GrandTotal) * 100 : 0;

                return new ServiceTotalRow
                {
                    Service  = ShortName(svc),
                    Total    = total,
                    Currency = Report.Currency,
                    Percent  = pct,
                    Fill     = Brushes[i % Brushes.Length]
                };
            })
            .OrderByDescending(r => r.Total)
            .ToList();
    }

    // ── Y-axis labels ─────────────────────────────────────────────────────────

    private decimal ChartMaxTotal => Report == null ? 0m :
        Report.MonthLabels
            .Select(m => Report.Entries.Where(e => e.MonthLabel == m).Sum(e => e.Amount))
            .DefaultIfEmpty(0m).Max();

    public string YAxis100 => FmtAmt(ChartMaxTotal);
    public string YAxis75  => FmtAmt(ChartMaxTotal * 0.75m);
    public string YAxis50  => FmtAmt(ChartMaxTotal * 0.50m);
    public string YAxis25  => FmtAmt(ChartMaxTotal * 0.25m);

    private static string FmtAmt(decimal v) =>
        v >= 1_000_000m ? $"${v / 1_000_000m:N1}M" :
        v >= 1_000m     ? $"${v / 1_000m:N0}K"      : $"${v:N0}";

    // ── Notify helpers ────────────────────────────────────────────────────────

    private void NotifyAllProps()
    {
        _billingBarsCache   = BuildBars();
        _serviceTotalsCache = BuildTotals();

        OnPropertyChanged(nameof(HasData));
        OnPropertyChanged(nameof(BillingBars));
        OnPropertyChanged(nameof(ServiceTotals));
        OnPropertyChanged(nameof(TotalCostText));
        OnPropertyChanged(nameof(AvgMonthlyCostText));
        OnPropertyChanged(nameof(MoMChangeText));
        OnPropertyChanged(nameof(MoMUp));
        OnPropertyChanged(nameof(PeriodRangeText));
        OnPropertyChanged(nameof(YAxis100));
        OnPropertyChanged(nameof(YAxis75));
        OnPropertyChanged(nameof(YAxis50));
        OnPropertyChanged(nameof(YAxis25));
        OnPropertyChanged(nameof(SelectedRangeText));
    }

    private static string ShortName(string name) => name switch
    {
        "Others"   => "Others",
        "Untagged" => "Untagged",
        _ => name
            .Replace("Amazon ", "")
            .Replace("AWS ", "")
            .Replace("Amazon Web Services ", "")
            .Trim()
    };

    private static string Esc(string s) =>
        (s.Contains(',') || s.Contains('"') || s.Contains('\n'))
            ? $"\"{s.Replace("\"", "\"\"")}\"" : s;

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _license.ProStatusChanged      -= _licenseChangedHandler;
            _accounts.ActiveAccountChanged -= OnAccountChanged;
        }
        base.Dispose(disposing);
    }
}
