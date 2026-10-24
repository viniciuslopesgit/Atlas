import Darwin
import Foundation

/// Writes files only their owner can read. `Data.write(.atomic)` creates its temporary file with the umask's
/// permissions (usually 0644) and a later chmod leaves a moment where a private key is readable by others;
/// here the bytes only ever exist in a file created 0600.
enum PrivateFile {
    /// Atomically replaces `url` with `data`, ending with `permissions` (0600 by default, 0400 for a key).
    static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            guard fchmod(fd, permissions) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try handle.close()
            guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Creates `folder` (and its parents) with the last component 0700.
    static func createFolder(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}
