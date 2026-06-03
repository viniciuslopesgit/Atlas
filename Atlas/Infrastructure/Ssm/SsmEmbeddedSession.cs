using System.Collections;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Amazon.Runtime;
using Atlas.Services.AWS;
using Microsoft.Win32.SafeHandles;

namespace Atlas.Infrastructure.Ssm;

/// <summary>
/// Embedded SSM session that uses the Windows Pseudo-Console (ConPTY) API to run
/// <c>aws ssm start-session</c> inside a real PTY and exposes the output/input as
/// byte streams, which the WebView2 + xterm.js layer consumes.
///
/// Requires Windows 10 1809 (build 17763) or later.
/// </summary>
public sealed class SsmEmbeddedSession : ISsmSession
{
    // ── P/Invoke ──────────────────────────────────────────────────────────────

    [StructLayout(LayoutKind.Sequential)]
    private struct COORD { public short X, Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOW
    {
        public int    cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public uint   dwX, dwY, dwXSize, dwYSize;
        public uint   dwXCountChars, dwYCountChars;
        public uint   dwFillAttribute;
        public uint   dwFlags;
        public ushort wShowWindow;
        public ushort cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFOW StartupInfo;
        public IntPtr       lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int    dwProcessId;
        public int    dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int CreatePseudoConsole(
        COORD size, SafeFileHandle hInput, SafeFileHandle hOutput,
        uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern int ResizePseudoConsole(IntPtr hPC, COORD size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(
        out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe,
        IntPtr lpPipeAttributes, int nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr lpAttributeList, uint dwFlags, IntPtr Attribute,
        IntPtr lpValue, IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessW(
        string? lpApplicationName,
        string  lpCommandLine,
        IntPtr  lpProcessAttributes,
        IntPtr  lpThreadAttributes,
        bool    bInheritHandles,
        uint    dwCreationFlags,
        IntPtr  lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    // ── Constants ─────────────────────────────────────────────────────────────

    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private const uint CREATE_UNICODE_ENVIRONMENT   = 0x00000400;

    // ProcThreadAttributeValue(22 /*PseudoConsole*/, Thread=false, Input=true, Additive=false)
    // = 22 | 0x00020000 = 0x00020016
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new(0x00020016);

    // ── Instance ──────────────────────────────────────────────────────────────

    private readonly FileStream  _inputStream;
    private readonly FileStream  _outputStream;
    private readonly IntPtr      _hpc;
    private readonly IntPtr      _hProcess;
    private readonly IntPtr      _hThread;
    private readonly Task        _readTask;
    private bool                 _disposed;

    public event EventHandler<byte[]>? DataReceived;
    public event EventHandler?         Exited;

    // ── Factory ───────────────────────────────────────────────────────────────

    /// <summary>
    /// Creates a ConPTY session running <c>aws ssm start-session</c>.
    /// Throws if the AWS CLI or the Session Manager Plugin cannot be located.
    /// </summary>
    public static SsmEmbeddedSession Create(
        string             instanceId,
        string             region,
        ImmutableCredentials creds,
        int cols = 220,
        int rows = 50)
    {
        var awsExe = FindAwsExe()
            ?? throw new InvalidOperationException(
                "AWS CLI (aws.exe) not found.\n" +
                "Install it with:  winget install Amazon.AWSCLI");

        var pluginExe = SsmPluginLocator.Find();
        var pluginDir = pluginExe != null ? Path.GetDirectoryName(pluginExe) : null;

        // ── Pipes ──────────────────────────────────────────────────────────
        if (!CreatePipe(out var pipeReadIn,  out var pipeWriteIn,  IntPtr.Zero, 0))
            throw new System.ComponentModel.Win32Exception();
        if (!CreatePipe(out var pipeReadOut, out var pipeWriteOut, IntPtr.Zero, 0))
            throw new System.ComponentModel.Win32Exception();

        // ── ConPTY ─────────────────────────────────────────────────────────
        var size = new COORD { X = (short)cols, Y = (short)rows };
        int hr = CreatePseudoConsole(size, pipeReadIn, pipeWriteOut, 0, out var hpc);
        if (hr != 0) throw new System.ComponentModel.Win32Exception(hr);

        // ConPTY has duplicated these handles internally; close the parent copies.
        pipeReadIn.Dispose();
        pipeWriteOut.Dispose();

        // ── Environment block ──────────────────────────────────────────────
        var envBytes = BuildEnvironmentBlock(creds, region, pluginDir);

        // ── Process ────────────────────────────────────────────────────────
        var cmdLine = $"\"{awsExe}\" ssm start-session --target \"{instanceId}\" --region \"{region}\"";
        var procInfo = StartWithConPty(hpc, cmdLine, envBytes);

        return new SsmEmbeddedSession(pipeWriteIn, pipeReadOut, hpc,
                                      procInfo.hProcess, procInfo.hThread);
    }

    private SsmEmbeddedSession(
        SafeFileHandle pipeWriteIn, SafeFileHandle pipeReadOut,
        IntPtr hpc, IntPtr hProcess, IntPtr hThread)
    {
        _hpc      = hpc;
        _hProcess = hProcess;
        _hThread  = hThread;
        // Anonymous pipes are synchronous (no FILE_FLAG_OVERLAPPED).
        // Both streams must use isAsync:false; async reads are done via Task.Run.
        _inputStream  = new FileStream(pipeWriteIn, FileAccess.Write, 4096, isAsync: false);
        _outputStream = new FileStream(pipeReadOut, FileAccess.Read,  4096, isAsync: false);
        _readTask = Task.Run(ReadLoop);
    }

    // ── Public API ────────────────────────────────────────────────────────────

    public void WriteInput(byte[] data)
    {
        if (_disposed) return;
        try { _inputStream.Write(data, 0, data.Length); _inputStream.Flush(); }
        catch { /* pipe closed — process has exited */ }
    }

    public void Resize(int cols, int rows)
    {
        if (!_disposed)
            ResizePseudoConsole(_hpc, new COORD { X = (short)cols, Y = (short)rows });
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        // Closing the ConPTY sends EOF to the child process's stdin, causing it to exit.
        ClosePseudoConsole(_hpc);

        try { _inputStream.Dispose();  } catch { }
        try { _outputStream.Dispose(); } catch { }

        CloseHandle(_hProcess);
        CloseHandle(_hThread);
    }

    // ── Internals ─────────────────────────────────────────────────────────────

    // Runs on a dedicated thread-pool thread (Task.Run in constructor).
    // Anonymous pipe handles are synchronous; we do blocking reads here.
    private void ReadLoop()
    {
        var buf = new byte[4096];
        try
        {
            int n;
            while ((n = _outputStream.Read(buf, 0, buf.Length)) > 0)
            {
                if (_disposed) break;
                var chunk = new byte[n];
                Buffer.BlockCopy(buf, 0, chunk, 0, n);
                DataReceived?.Invoke(this, chunk);
            }
        }
        catch { /* pipe closed — normal exit */ }

        Exited?.Invoke(this, EventArgs.Empty);
    }

    // ── Process creation with ConPTY ──────────────────────────────────────────

    private static PROCESS_INFORMATION StartWithConPty(IntPtr hpc, string cmdLine, byte[] envBlock)
    {
        // Step 1: Calculate size for the attribute list (one attribute).
        var attrListSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrListSize);
        // ^ returns false (expected); attrListSize is now filled

        var attrList = Marshal.AllocHGlobal(attrListSize);
        try
        {
            if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrListSize))
                throw new System.ComponentModel.Win32Exception();

            // Step 2: Set PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE.
            // UpdateProcThreadAttribute stores a POINTER to the HPCON value,
            // so we allocate stable (unmanaged) memory to hold it.
            var hpcMem = Marshal.AllocHGlobal(IntPtr.Size);
            try
            {
                Marshal.WriteIntPtr(hpcMem, hpc);
                if (!UpdateProcThreadAttribute(
                        attrList, 0,
                        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                        hpcMem, (IntPtr)IntPtr.Size,
                        IntPtr.Zero, IntPtr.Zero))
                    throw new System.ComponentModel.Win32Exception();

                // Step 3: Build STARTUPINFOEX.
                var si = new STARTUPINFOEX
                {
                    StartupInfo    = new STARTUPINFOW { cb = Marshal.SizeOf<STARTUPINFOEX>() },
                    lpAttributeList = attrList,
                };

                // Step 4: Pin environment block.
                var envMem = Marshal.AllocHGlobal(envBlock.Length);
                try
                {
                    Marshal.Copy(envBlock, 0, envMem, envBlock.Length);

                    // Step 5: Create the process.
                    if (!CreateProcessW(
                            null, cmdLine,
                            IntPtr.Zero, IntPtr.Zero,
                            bInheritHandles: false,
                            EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                            envMem, null,
                            ref si, out var procInfo))
                        throw new System.ComponentModel.Win32Exception();

                    return procInfo;
                }
                finally { Marshal.FreeHGlobal(envMem); }
            }
            finally { Marshal.FreeHGlobal(hpcMem); }
        }
        finally
        {
            DeleteProcThreadAttributeList(attrList);
            Marshal.FreeHGlobal(attrList);
        }
    }

    // ── Environment block helper ──────────────────────────────────────────────

    private static byte[] BuildEnvironmentBlock(
        ImmutableCredentials creds, string region, string? pluginDir)
    {
        // Start from the current process environment and overlay our values.
        var vars = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
            vars[(string)e.Key] = (string)(e.Value ?? "");

        vars["AWS_ACCESS_KEY_ID"]     = creds.AccessKey;
        vars["AWS_SECRET_ACCESS_KEY"] = creds.SecretKey;

        if (string.IsNullOrEmpty(creds.Token))
            vars.Remove("AWS_SESSION_TOKEN");
        else
            vars["AWS_SESSION_TOKEN"] = creds.Token;

        vars["AWS_REGION"]         = region;
        vars["AWS_DEFAULT_REGION"] = region;

        // Prepend the plugin directory to PATH so aws.exe can find the plugin.
        if (pluginDir != null)
        {
            var currentPath = vars.TryGetValue("PATH", out var p) ? p : "";
            var already = currentPath
                .Split(Path.PathSeparator)
                .Any(d => string.Equals(
                    d.TrimEnd(Path.DirectorySeparatorChar),
                    pluginDir.TrimEnd(Path.DirectorySeparatorChar),
                    StringComparison.OrdinalIgnoreCase));

            if (!already)
                vars["PATH"] = pluginDir + Path.PathSeparator + currentPath;
        }

        // Build null-terminated Unicode environment block: KEY=VALUE\0…\0\0
        var sb = new StringBuilder();
        foreach (var kv in vars)
            sb.Append(kv.Key).Append('=').Append(kv.Value).Append('\0');
        sb.Append('\0');

        return Encoding.Unicode.GetBytes(sb.ToString());
    }

    // ── aws.exe locator ───────────────────────────────────────────────────────

    internal static string? FindAwsExe()
    {
        var pathVar = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var dir in pathVar.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            if (File.Exists(Path.Combine(dir, "aws.exe"))) return Path.Combine(dir, "aws.exe");
            if (File.Exists(Path.Combine(dir, "aws")))     return Path.Combine(dir, "aws");
        }

        string[] known =
        [
            @"C:\Program Files\Amazon\AWSCLIV2\aws.exe",
            @"C:\Program Files (x86)\Amazon\AWSCLIV2\aws.exe",
        ];
        return known.FirstOrDefault(File.Exists);
    }
}
