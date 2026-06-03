namespace Atlas.Services;

public interface IAnalyticsService
{
    void TrackAppStart();
    void TrackPageView(string pageName);
    void TrackEvent(string eventName, Dictionary<string, object>? parameters = null);
}
