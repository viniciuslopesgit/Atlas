namespace Atlas.Services;

/// <summary>
/// Decouples Pro feature-gating from the UI. Any ViewModel can request the
/// "Upgrade to Pro" modal by calling <see cref="Prompt"/>; the MainViewModel
/// listens for <see cref="UpgradeRequested"/> and shows the in-window overlay.
/// </summary>
public interface IUpgradeService
{
    /// <summary>Raised with a short, user-facing reason describing the locked feature.</summary>
    event EventHandler<string>? UpgradeRequested;

    /// <summary>Ask the shell to surface the upgrade overlay for the given feature.</summary>
    void Prompt(string reason);
}

public sealed class UpgradeService : IUpgradeService
{
    public event EventHandler<string>? UpgradeRequested;

    public void Prompt(string reason) => UpgradeRequested?.Invoke(this, reason);
}
