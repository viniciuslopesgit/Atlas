using System.IO;
using System.Text;

namespace Atlas.Infrastructure.Logging;

public static class FileLogger
{
    private static readonly string LogPath = Path.Combine(
        AppDomain.CurrentDomain.BaseDirectory, "Atlas-errors.txt");

    private static readonly object _lock = new();

    // Keep the log file from growing unboundedly: trim to this size after each write.
    private const long MaxLogBytes = 512 * 1024; // 512 KB

    public static void Log(string level, string message, Exception? ex = null)
    {
        try
        {
            var sb = new StringBuilder();
            sb.AppendLine($"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [{level}] {message}");
            if (ex != null)
            {
                sb.AppendLine($"  Exception : {ex.GetType().FullName}: {ex.Message}");
                sb.AppendLine($"  StackTrace: {ex.StackTrace}");
                if (ex.InnerException != null)
                    sb.AppendLine($"  Inner     : {ex.InnerException.GetType().FullName}: {ex.InnerException.Message}");
            }
            sb.AppendLine(new string('─', 80));

            lock (_lock)
            {
                File.AppendAllText(LogPath, sb.ToString(), Encoding.UTF8);
                TrimLogIfNeeded();
            }
        }
        catch
        {
            // Never let logging crash the app
        }
    }

    public static void Info(string message)    => Log("INFO ", message);
    public static void Warning(string message) => Log("WARN ", message);
    public static void Error(string message, Exception? ex = null) => Log("ERROR", message, ex);

    private static void TrimLogIfNeeded()
    {
        try
        {
            var info = new FileInfo(LogPath);
            if (!info.Exists || info.Length <= MaxLogBytes) return;

            // Keep only the last MaxLogBytes worth of content (trim oldest entries at file start)
            using var stream = new FileStream(LogPath, FileMode.Open, FileAccess.ReadWrite);
            stream.Seek(-MaxLogBytes, SeekOrigin.End);

            // Advance to the next line boundary to avoid splitting a log entry
            int b;
            while ((b = stream.ReadByte()) != -1 && b != '\n') { }

            var remaining = new byte[stream.Length - stream.Position];
            stream.ReadExactly(remaining, 0, remaining.Length);

            stream.SetLength(0);
            stream.Write(remaining, 0, remaining.Length);
        }
        catch
        {
            // Trim failure is non-fatal
        }
    }
}
