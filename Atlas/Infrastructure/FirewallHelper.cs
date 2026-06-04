using System.ComponentModel;
using System.Diagnostics;
using Atlas.Infrastructure.Logging;

namespace Atlas.Infrastructure;

public static class FirewallHelper
{
    private const string RuleName = "Atlas - Allow HTTPS";

    /// <summary>Best-effort rule creation without UAC — call from install/first-run hooks.</summary>
    public static void TryAddOutboundRule() => RunNetsh(useElevation: false);

    /// <summary>
    /// Requests UAC elevation and creates the outbound rule.
    /// Returns true if the rule was added successfully, false if the user cancelled or it failed.
    /// Must be called from a background thread (blocks until the elevated process exits).
    /// </summary>
    public static bool TryAddOutboundRuleElevated() => RunNetsh(useElevation: true);

    private static bool RunNetsh(bool useElevation)
    {
        var exe = Environment.ProcessPath
                  ?? Process.GetCurrentProcess().MainModule?.FileName;
        if (exe is null) return false;

        var args = $"advfirewall firewall add rule name=\"{RuleName}\" dir=out " +
                   $"action=allow program=\"{exe}\" enable=yes " +
                   $"protocol=TCP remoteport=443 profile=any";

        var psi = new ProcessStartInfo("netsh", args) { CreateNoWindow = true };
        if (useElevation)
        {
            psi.UseShellExecute = true;
            psi.Verb            = "runas";
        }

        try
        {
            using var p = Process.Start(psi)!;
            p.WaitForExit(15_000);
            FileLogger.Info($"FirewallHelper — rule add exit={p.ExitCode} elevated={useElevation}");
            return p.ExitCode == 0;
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            FileLogger.Info("FirewallHelper — UAC cancelled by user");
            return false;
        }
        catch (Exception ex)
        {
            FileLogger.Warning($"FirewallHelper — rule add failed: {ex.Message}");
            return false;
        }
    }
}
