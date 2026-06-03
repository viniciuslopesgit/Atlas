namespace Atlas.Services.AWS;

/// <summary>
/// Represents an active SSM terminal session.
/// Implementations (e.g. ConPTY-backed) are decoupled from the view layer via this interface.
/// </summary>
public interface ISsmSession : IDisposable
{
    /// <summary>Raw VT/ANSI bytes received from the remote shell.</summary>
    event EventHandler<byte[]>? DataReceived;

    /// <summary>Fired when the remote process exits and no more data will arrive.</summary>
    event EventHandler? Exited;

    /// <summary>Sends raw bytes (keyboard input, paste, etc.) to the remote shell.</summary>
    void WriteInput(byte[] data);

    /// <summary>Informs the remote PTY of a terminal resize.</summary>
    void Resize(int cols, int rows);
}
