using System.IO;
using System.Runtime.InteropServices;

namespace Atlas.Infrastructure.Ssm;

/// <summary>
/// Locates the AWS Session Manager Plugin binary on the current machine.
/// </summary>
public static class SsmPluginLocator
{
    private static readonly string BinaryName =
        RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
            ? "session-manager-plugin.exe"
            : "session-manager-plugin";

    private static readonly string[] KnownPaths =
        RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
            ? [
                @"C:\Program Files\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe",
                @"C:\Program Files (x86)\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe",
              ]
            : RuntimeInformation.IsOSPlatform(OSPlatform.OSX)
            ? [
                "/usr/local/sessionmanagerplugin/bin/session-manager-plugin",
                "/usr/local/bin/session-manager-plugin",
                "/opt/homebrew/bin/session-manager-plugin",
              ]
            : [
                "/usr/local/bin/session-manager-plugin",
                "/usr/bin/session-manager-plugin",
                "/snap/bin/session-manager-plugin",
              ];

    /// <summary>Returns the full path to the plugin, or null if it is not installed.</summary>
    public static string? Find()
    {
        // 1. Search PATH entries first
        var pathVar = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var dir in pathVar.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir, BinaryName);
            if (File.Exists(candidate)) return candidate;
        }

        // 2. Fall back to well-known installation directories
        return KnownPaths.FirstOrDefault(File.Exists);
    }

    public static bool IsInstalled() => Find() is not null;

    public static string InstallUrl =>
        "https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html";

    public static string InstallInstructions =>
        RuntimeInformation.IsOSPlatform(OSPlatform.OSX)
            ? "brew install --cask session-manager-plugin"
            : RuntimeInformation.IsOSPlatform(OSPlatform.Windows)
            ? "Download the installer from the AWS documentation (see link below)."
            : "sudo apt install session-manager-plugin  # or see the link below for your distro";
}
