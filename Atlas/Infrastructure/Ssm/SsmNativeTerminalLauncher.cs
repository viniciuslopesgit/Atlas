using System.IO;
using System.Text;
using System.Text.Json;
using System.Diagnostics;
using Amazon.Runtime;

namespace Atlas.Infrastructure.Ssm;

/// <summary>
/// Launches AWS SSM sessions in a native OS terminal window.
///
/// Strategy (tried in order):
///   1. AWS CLI  —  aws ssm start-session  (preferred)
///      The CLI handles StartSession + plugin invocation the same way a user would
///      from their own terminal.  No JSON quoting, no console-ownership fights.
///
///   2. Plugin   —  session-manager-plugin directly  (fallback if CLI absent)
///      Builds the six-argument call manually and launches via PowerShell.
///
/// Both strategies open powershell.exe via ShellExecute (traditional conhost.exe
/// window, NOT Windows Terminal / ConPTY).  The session-manager-plugin calls
/// SetConsoleMode to enter raw/interactive mode; ConPTY intercepts those calls
/// and prevents stdin from reaching the plugin.  A real Win32 console avoids this.
/// </summary>
public static class SsmNativeTerminalLauncher
{
    // ── Approach 1 : AWS CLI ─────────────────────────────────────────────────

    /// <summary>
    /// Tries to open the session via <c>aws ssm start-session</c>.
    /// Atlas's active credentials are injected into the child process environment
    /// so the correct account / assumed-role is used regardless of CLI config.
    /// Returns <c>false</c> if the AWS CLI binary is not found.
    /// </summary>
    public static bool LaunchViaCli(
        string instanceId,
        string region,
        ImmutableCredentials creds)
    {
        if (!IsAwsCliAvailable()) return false;

        // The AWS CLI invokes session-manager-plugin by searching PATH.
        // When Atlas is launched from a shortcut / startup its PATH is the system
        // PATH at that moment — it may not include the directory where the user
        // installed the plugin.  We locate the plugin ourselves and prepend its
        // directory to PATH so the child aws process can find it.
        var pluginExe = SsmPluginLocator.Find();
        if (pluginExe == null) return false;          // plugin absent → CLI won't work either
        var pluginDir = Path.GetDirectoryName(pluginExe)!;

        var id      = Guid.NewGuid().ToString("N")[..8];
        var ps1File = Path.Combine(Path.GetTempPath(), $"ssm_cli_{id}.ps1");

        File.WriteAllText(ps1File, BuildCliScript(instanceId, region, ps1File),
                          new UTF8Encoding(false));

        // Temporarily inject credentials + plugin dir into the current process
        // environment.  Child processes created via ShellExecute inherit a snapshot
        // of this environment.  We restore everything immediately after launch.
        var savedCreds = SaveAndInjectCredentials(creds, region);
        var savedPath  = PrependToPath(pluginDir);
        try
        {
            var psArgs = $"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{ps1File}\"";
            return TryLaunch("powershell.exe", psArgs) ||
                   TryLaunch("pwsh.exe",       psArgs);
        }
        finally
        {
            RestoreCredentials(savedCreds);
            Environment.SetEnvironmentVariable("PATH", savedPath);
        }
    }

    /// <summary>
    /// Prepends <paramref name="dir"/> to the process PATH if not already present.
    /// Returns the original PATH value so the caller can restore it.
    /// </summary>
    private static string PrependToPath(string dir)
    {
        var current = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        var already = current.Split(Path.PathSeparator)
                             .Any(d => string.Equals(
                                          d.TrimEnd(Path.DirectorySeparatorChar),
                                          dir.TrimEnd(Path.DirectorySeparatorChar),
                                          StringComparison.OrdinalIgnoreCase));
        if (!already)
            Environment.SetEnvironmentVariable("PATH", dir + Path.PathSeparator + current);
        return current;
    }

    private static bool IsAwsCliAvailable()
    {
        // Search PATH
        var pathVar = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var dir in pathVar.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            if (File.Exists(Path.Combine(dir, "aws.exe"))) return true;
            if (File.Exists(Path.Combine(dir, "aws")))     return true;
        }
        // Well-known AWS CLI v2 install paths on Windows
        string[] known =
        [
            @"C:\Program Files\Amazon\AWSCLIV2\aws.exe",
            @"C:\Program Files (x86)\Amazon\AWSCLIV2\aws.exe",
        ];
        return known.Any(File.Exists);
    }

    private static (string? key, string? sec, string? tok, string? reg, string? regDef)
        SaveAndInjectCredentials(ImmutableCredentials creds, string region)
    {
        var saved = (
            Environment.GetEnvironmentVariable("AWS_ACCESS_KEY_ID"),
            Environment.GetEnvironmentVariable("AWS_SECRET_ACCESS_KEY"),
            Environment.GetEnvironmentVariable("AWS_SESSION_TOKEN"),
            Environment.GetEnvironmentVariable("AWS_REGION"),
            Environment.GetEnvironmentVariable("AWS_DEFAULT_REGION")
        );
        Environment.SetEnvironmentVariable("AWS_ACCESS_KEY_ID",     creds.AccessKey);
        Environment.SetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", creds.SecretKey);
        Environment.SetEnvironmentVariable("AWS_SESSION_TOKEN",
            string.IsNullOrEmpty(creds.Token) ? null : creds.Token);
        Environment.SetEnvironmentVariable("AWS_REGION",            region);
        Environment.SetEnvironmentVariable("AWS_DEFAULT_REGION",    region);
        return saved;
    }

    private static void RestoreCredentials(
        (string? key, string? sec, string? tok, string? reg, string? regDef) saved)
    {
        Environment.SetEnvironmentVariable("AWS_ACCESS_KEY_ID",     saved.key);
        Environment.SetEnvironmentVariable("AWS_SECRET_ACCESS_KEY", saved.sec);
        Environment.SetEnvironmentVariable("AWS_SESSION_TOKEN",     saved.tok);
        Environment.SetEnvironmentVariable("AWS_REGION",            saved.reg);
        Environment.SetEnvironmentVariable("AWS_DEFAULT_REGION",    saved.regDef);
    }

    // Builds the PS1 wrapper for the CLI approach.
    // Credentials are NOT written to the file — they live only in env vars.
    // In @"" + $ strings:  {{ → {   }} → }   "" → "   {expr} → interpolated
    private static string BuildCliScript(string instanceId, string region, string ps1File)
    {
        static string Sq(string s) => s.Replace("'", "''");

        return $@"$host.UI.RawUI.WindowTitle = 'SSM {Sq(instanceId)} [{Sq(region)}]'

Write-Host ''
Write-Host '  AWS Session Manager' -ForegroundColor Cyan
Write-Host '  Instance : {Sq(instanceId)}' -ForegroundColor Gray
Write-Host '  Region   : {Sq(region)}' -ForegroundColor Gray
Write-Host ''

try {{
    aws ssm start-session --target '{Sq(instanceId)}' --region '{Sq(region)}'
}} catch {{
    Write-Host (""[Error] "" + $_) -ForegroundColor Red
}} finally {{
    Remove-Item '{Sq(ps1File)}' -Force -ErrorAction SilentlyContinue
}}

Write-Host ''
Write-Host '[Session closed]' -ForegroundColor Yellow
Write-Host 'Press any key to close...' -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
";
    }

    // ── Approach 2 : session-manager-plugin directly ─────────────────────────

    /// <summary>
    /// Launches the <c>session-manager-plugin</c> binary directly.
    /// Called as a fallback when the AWS CLI is not installed.
    /// </summary>
    public static void Launch(
        string pluginPath,
        string sessionId,
        string streamUrl,
        string tokenValue,
        string region,
        string instanceId,
        string documentName = "AWS-StartSession",
        string profile      = "")
    {
        var id       = Guid.NewGuid().ToString("N")[..8];
        var tmpDir   = Path.GetTempPath();
        var respFile = Path.Combine(tmpDir, $"ssm_resp_{id}.json");
        var prmsFile = Path.Combine(tmpDir, $"ssm_prms_{id}.json");
        var ps1File  = Path.Combine(tmpDir, $"ssm_sess_{id}.ps1");
        var endpoint = $"https://ssm.{region}.amazonaws.com";

        // Write the two JSON blobs to temp files — no quoting nightmare in the script
        File.WriteAllText(respFile, JsonSerializer.Serialize(new
        {
            SessionId  = sessionId,
            TokenValue = tokenValue,
            StreamUrl  = streamUrl,
        }), Encoding.UTF8);

        File.WriteAllText(prmsFile, JsonSerializer.Serialize(new
        {
            Target       = instanceId,
            DocumentName = documentName,
        }), Encoding.UTF8);

        File.WriteAllText(ps1File, BuildPluginScript(pluginPath, respFile, prmsFile, ps1File,
            region, profile, endpoint, instanceId), new UTF8Encoding(false));

        var psArgs = $"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{ps1File}\"";

        if (!TryLaunch("powershell.exe", psArgs) &&
            !TryLaunch("pwsh.exe",       psArgs) &&
            !TryLaunch("wt.exe",        $"--title \"SSM — {instanceId}\" -- powershell.exe {psArgs}"))
        {
            throw new InvalidOperationException(
                "No terminal emulator found (powershell, pwsh, or wt).");
        }
    }

    // ── Shared helpers ────────────────────────────────────────────────────────

    private static bool TryLaunch(string exe, string args)
    {
        try
        {
            Process.Start(new ProcessStartInfo(exe, args) { UseShellExecute = true });
            return true;
        }
        catch { return false; }
    }

    // ── Plugin script builder ─────────────────────────────────────────────────
    //
    // PowerShell 5.1 silently DROPS empty-string arguments when calling native
    // executables (& 'exe' '').  The profile arg (position 4) can be empty, so
    // we build the full Win32 argument string ourselves (QuoteWin32) and pass it
    // via --% (stop-parsing) + env var, which bypasses PS argument processing.
    //
    // In @"" strings:  "" → literal "    {{ → literal {    }} → literal }
    // In Format:       {0} … {7} → the C# values below
    private static string BuildPluginScript(
        string pluginPath, string respFile, string prmsFile, string ps1File,
        string region, string profile, string endpoint, string instanceId)
    {
        // Escape single quotes for PS single-quoted strings (' → '')
        static string Sq(string s) => s.Replace("'", "''");

        return string.Format(@"
$host.UI.RawUI.WindowTitle = 'SSM {0} [{1}]'

Write-Host ''
Write-Host '  AWS Session Manager' -ForegroundColor Cyan
Write-Host '  Instance : {0}' -ForegroundColor Gray
Write-Host '  Region   : {1}' -ForegroundColor Gray
Write-Host ''

$resp = [System.IO.File]::ReadAllText('{2}')
$prms = [System.IO.File]::ReadAllText('{3}')

# QuoteWin32: wrap in double-quotes, escape "" as \"" and \ as \\
# so empty strings become """" and JSON passes verbatim to the plugin.
function QuoteWin32([string]$s) {{
    '""' + $s.Replace('\', '\\').Replace('""', '\""') + '""'
}}

# Build the raw Windows command-line string (6 positional args after the binary)
$argStr  = (QuoteWin32 $resp) + ' '
$argStr += (QuoteWin32 '{1}') + ' '   # region
$argStr += (QuoteWin32 'StartSession') + ' '
$argStr += (QuoteWin32 '{5}') + ' '   # profile (may be empty → becomes """")
$argStr += (QuoteWin32 $prms) + ' '
$argStr += (QuoteWin32 '{6}')          # endpoint

# Store in env var and use --% so PS passes %_SSM_PLUGIN_ARGS% verbatim to
# CreateProcess — no empty-string dropping, no PS re-quoting of JSON.
# Using & (not ProcessStartInfo) gives the plugin direct console ownership.
$env:_SSM_PLUGIN_ARGS = $argStr
try {{
    & '{4}' --% %_SSM_PLUGIN_ARGS%
}} catch {{
    Write-Host (""[Error] "" + $_) -ForegroundColor Red
}} finally {{
    Remove-Item '{2}','{3}','{7}' -Force -ErrorAction SilentlyContinue
    Remove-Item env:_SSM_PLUGIN_ARGS -ErrorAction SilentlyContinue
}}

Write-Host ''
Write-Host '[Session closed]' -ForegroundColor Yellow
Write-Host 'Press any key to close...' -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
",
            Sq(instanceId),  // {0}
            Sq(region),      // {1}
            Sq(respFile),    // {2}
            Sq(prmsFile),    // {3}
            Sq(pluginPath),  // {4}
            Sq(profile),     // {5}
            Sq(endpoint),    // {6}
            Sq(ps1File));    // {7}
    }
}
