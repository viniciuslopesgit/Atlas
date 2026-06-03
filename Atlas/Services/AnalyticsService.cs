using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using Atlas.Infrastructure.Logging;

namespace Atlas.Services;

/// <summary>
/// Sends anonymous usage events to Google Analytics 4 via the Measurement Protocol.
/// Replace MeasurementId and ApiSecret with your GA4 property credentials.
/// GA4 Measurement Protocol reference: https://developers.google.com/analytics/devguides/collection/protocol/ga4
/// </summary>
public sealed class AnalyticsService : IAnalyticsService
{
    // ── Replace these with your GA4 property credentials ──────────────
    private const string MeasurementId = "G-XXXXXXXXXX";
    private const string ApiSecret     = "YOUR_API_SECRET";
    // ──────────────────────────────────────────────────────────────────

    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(5) };

    private readonly string _clientId;
    private readonly bool   _enabled;

    public AnalyticsService()
    {
        _enabled  = MeasurementId != "G-XXXXXXXXXX" && ApiSecret != "YOUR_API_SECRET";
        _clientId = LoadOrCreateClientId();
    }

    public void TrackAppStart() =>
        TrackEvent("app_start", new Dictionary<string, object> { ["app_version"] = GetAppVersion() });

    public void TrackPageView(string pageName) =>
        TrackEvent("page_view", new Dictionary<string, object> { ["page_title"] = pageName });

    public void TrackEvent(string eventName, Dictionary<string, object>? parameters = null)
    {
        if (!_enabled) return;
        _ = SendAsync(eventName, parameters);
    }

    private async Task SendAsync(string eventName, Dictionary<string, object>? parameters)
    {
        try
        {
            var eventParams = new Dictionary<string, object>(parameters ?? [])
            {
                ["engagement_time_msec"] = 100
            };

            var payload = new
            {
                client_id = _clientId,
                events = new[]
                {
                    new { name = eventName, @params = eventParams }
                }
            };

            var json    = JsonSerializer.Serialize(payload);
            var content = new StringContent(json, Encoding.UTF8, "application/json");
            var url     = $"https://www.google-analytics.com/mp/collect?measurement_id={MeasurementId}&api_secret={ApiSecret}";

            await Http.PostAsync(url, content);
        }
        catch (Exception ex)
        {
            FileLogger.Warning($"Analytics — failed to send event '{eventName}': {ex.Message}");
        }
    }

    private static string LoadOrCreateClientId()
    {
        try
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var path    = Path.Combine(appData, "Atlas", "analytics_client_id.dat");

            if (File.Exists(path))
            {
                var stored = File.ReadAllText(path).Trim();
                if (Guid.TryParse(stored, out _)) return stored;
            }

            var id = Guid.NewGuid().ToString();
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, id);
            return id;
        }
        catch (Exception ex)
        {
            FileLogger.Warning($"Analytics — could not load/create client ID: {ex.Message}");
            return Guid.NewGuid().ToString();
        }
    }

    private static string GetAppVersion()
    {
        var version = System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version;
        return version?.ToString(3) ?? "0.0.0";
    }
}
