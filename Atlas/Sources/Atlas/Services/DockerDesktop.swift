import Foundation
import Security

/// Installs Docker Desktop for stacks when the Mac has no container runtime: the official DMG from docker.com,
/// its code signature checked against Docker Inc's team, Docker.app copied to /Applications. Docker's own
/// license and privileged setup appear when Docker Desktop opens for the first time.
@MainActor
final class DockerDesktopInstaller: ObservableObject {
    enum Phase: Equatable {
        case idle, downloading(Double), verifying, installing, done, failed(String)
        var isWorking: Bool {
            switch self {
            case .downloading, .verifying, .installing: true
            default: false
            }
        }
    }

    /// Set once the first-launch prompt has been answered, so it is not shown again.
    nonisolated static let promptedKey = "dockerDesktopPrompted"
    /// Docker Inc's Developer ID team.
    nonisolated static let teamIdentifier = "9BNSXJN65R"
    /// Docker.dmg is under 1 GB; anything past this is not the file we asked for.
    nonisolated static let maxDownloadBytes: Int64 = 3_000_000_000

    nonisolated static var downloadURL: URL {
        #if arch(arm64)
        URL(string: "https://desktop.docker.com/mac/main/arm64/Docker.dmg")!
        #else
        URL(string: "https://desktop.docker.com/mac/main/amd64/Docker.dmg")!
        #endif
    }

    @Published private(set) var phase: Phase = .idle

    private let session: URLSession
    private let applications: URL
    private let hdiutil: String
    private let verify: @Sendable (URL) -> Bool
    private let workRoot: URL

    init(session: URLSession = .shared, applications: URL = URL(fileURLWithPath: "/Applications", isDirectory: true),
         hdiutil: String = "/usr/bin/hdiutil", workRoot: URL = FileManager.default.temporaryDirectory,
         verify: @escaping @Sendable (URL) -> Bool = { DockerDesktopInstaller.isSignedByDocker($0) }) {
        self.session = session
        self.workRoot = workRoot
        self.applications = applications
        self.hdiutil = hdiutil
        self.verify = verify
    }

    var installedApp: URL { applications.appendingPathComponent("Docker.app") }

    /// Download, mount, verify, copy. Everything downloaded or mounted is gone afterwards, whatever happens.
    func install() async {
        guard !phase.isWorking else { return }
        guard !FileManager.default.fileExists(atPath: installedApp.path) else {
            phase = .failed("Docker.app is already in \(applications.path). Open it to finish its setup.")
            return
        }
        let work = workRoot.appendingPathComponent("atlas-docker-\(UUID().uuidString)", isDirectory: true)
        let dmg = work.appendingPathComponent("Docker.dmg"), mount = work.appendingPathComponent("mnt", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
            phase = .downloading(0)
            try await download(to: dmg)

            phase = .verifying
            let tool = TerraformCLI(binary: hdiutil, timeout: 300)
            let attached = await tool.run(["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path], in: work)
            guard attached.isSuccess else { throw Failure("Could not open the Docker Desktop disk image.") }
            let copied: Result<Void, Failure> = await copyVerifiedApp(from: mount.appendingPathComponent("Docker.app"))
            // Unmounted before the folder is removed, whether or not the copy worked.
            _ = await TerraformCLI(binary: hdiutil, timeout: 60).run(["detach", "-force", mount.path], in: work)
            try copied.get()
            phase = .done
        } catch let f as Failure {
            phase = .failed(f.message)
        } catch let e as DockerDownloadError {
            phase = .failed(e.message)
        } catch {
            phase = .failed("The download failed: \(error.localizedDescription)")
        }
    }

    private func copyVerifiedApp(from app: URL) async -> Result<Void, Failure> {
        let verify = self.verify
        guard await Task.detached(operation: { verify(app) }).value else {
            return .failure(Failure("The downloaded Docker Desktop is not signed by Docker Inc. Nothing was installed."))
        }
        phase = .installing
        // Copied under a temporary name and renamed when complete: a failed copy never leaves a broken Docker.app.
        let destination = installedApp
        let partial = applications.appendingPathComponent(".Docker.app.atlas-\(UUID().uuidString)")
        do {
            try await Task.detached {
                do {
                    try FileManager.default.copyItem(at: app, to: partial)
                    try FileManager.default.moveItem(at: partial, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: partial)
                    throw error
                }
            }.value
            return .success(())
        } catch {
            return .failure(Failure("Could not copy Docker.app to \(applications.path) (an administrator account is needed). Install it from docker.com."))
        }
    }

    private struct Failure: Error { let message: String; init(_ m: String) { message = m } }

    /// Streams the DMG straight into `file` (no temporary file elsewhere) and reports progress.
    private func download(to file: URL) async throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { throw Failure("Could not write the download.") }
        let sink = DownloadSink(handle: handle, limit: Self.maxDownloadBytes)
        let task = session.dataTask(with: Self.downloadURL)
        task.delegate = sink
        task.resume()
        while !sink.isFinished {
            phase = .downloading(sink.fraction)
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { task.cancel() }
        }
        try? handle.close()
        try sink.result?.get()
    }

    /// Valid signature (nested code included) from a Developer ID certificate of Docker Inc's team.
    nonisolated static func isSignedByDocker(_ app: URL) -> Bool {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\"" as CFString
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckNestedCode | kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}

private final class DownloadSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var expected: Int64 = 0, received: Int64 = 0
    private var outcome: Result<Void, Error>?
    private let limit: Int64

    init(handle: FileHandle, limit: Int64) {
        self.handle = handle
        self.limit = limit
    }

    private var tooLarge: DockerDownloadError {
        DockerDownloadError(message: "The download is larger than \(limit / 1_000_000_000) GB, which Docker.dmg never is. Nothing was installed.")
    }

    var isFinished: Bool { lock.withLock { outcome != nil } }
    var result: Result<Void, Error>? { lock.withLock { outcome } }
    var fraction: Double { lock.withLock { expected > 0 ? min(1, Double(received) / Double(expected)) : 0 } }

    private func finish(_ r: Result<Void, Error>) { lock.withLock { if outcome == nil { outcome = r } } }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            finish(.failure(DockerDownloadError(message: "docker.com answered HTTP \(status).")))
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= limit else {
            finish(.failure(tooLarge))
            completionHandler(.cancel)
            return
        }
        lock.withLock { expected = response.expectedContentLength }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            guard lock.withLock({ received + Int64(data.count) }) <= limit else { throw tooLarge }
            try handle.write(contentsOf: data)
            lock.withLock { received += Int64(data.count) }
        } catch {
            finish(.failure(error))
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(error.map { .failure($0) } ?? .success(()))
    }
}

struct DockerDownloadError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
