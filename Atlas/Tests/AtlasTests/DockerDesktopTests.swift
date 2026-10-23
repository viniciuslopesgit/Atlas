import Foundation
import Testing
@testable import Atlas

/// Answers the Docker.dmg download; its own statics, so it never races other suites over MockURLProtocol's handler.
final class DockerDmgProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var contentLength = "9"
    nonisolated(unsafe) static var urls: [URL] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, length) = Self.lock.withLock { Self.urls.append(request.url!); return (Self.status, Self.contentLength) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                              headerFields: ["Content-Length": length])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("fake dmg\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct DockerDesktopInstallerTests {
    struct Setup {
        let root: URL, applications: URL, work: URL, hdiutil: URL
        var hdiutilLog: String { (try? String(contentsOf: root.appendingPathComponent("hdiutil.log"), encoding: .utf8)) ?? "" }
    }

    private func setup(status: Int = 200, contentLength: String = "9", unreadableFile: Bool = false) throws -> Setup {
        let root = TestTemp.root.appendingPathComponent("docker-desktop-\(UUID().uuidString)", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        for d in [applications, work] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let hdiutil = root.appendingPathComponent("hdiutil")
        // "Mounts" by creating Docker.app in the mount point; logs every call.
        try Data("""
        #!/bin/bash
        echo "$*" >> "\(root.path)/hdiutil.log"
        if [ "$1" = attach ]; then
          while [ $# -gt 0 ]; do [ "$1" = -mountpoint ] && mp="$2"; shift; done
          mkdir -p "$mp/Docker.app/Contents" && echo plist > "$mp/Docker.app/Contents/Info.plist"
          \(unreadableFile ? #"echo x > "$mp/Docker.app/Contents/zz-unreadable" && chmod 000 "$mp/Docker.app/Contents/zz-unreadable""# : "")
        fi
        """.utf8).write(to: hdiutil)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hdiutil.path)
        DockerDmgProtocol.lock.withLock {
            DockerDmgProtocol.status = status; DockerDmgProtocol.contentLength = contentLength; DockerDmgProtocol.urls = []
        }
        return Setup(root: root, applications: applications, work: work, hdiutil: hdiutil)
    }

    @MainActor private func installer(_ s: Setup, signed: Bool) -> DockerDesktopInstaller {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DockerDmgProtocol.self]
        return DockerDesktopInstaller(session: URLSession(configuration: config), applications: s.applications,
                                      hdiutil: s.hdiutil.path, workRoot: s.work, verify: { _ in signed })
    }

    private func leftovers(_ s: Setup) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: s.work.path) }

    @Test @MainActor func downloadsVerifiesAndInstallsDockerDesktop() async throws {
        let s = try setup()
        let i = installer(s, signed: true)
        await i.install()
        #expect(i.phase == .done, "\(i.phase)")
        #expect(FileManager.default.fileExists(atPath: s.applications.appendingPathComponent("Docker.app/Contents/Info.plist").path))
        let url = try #require(DockerDmgProtocol.lock.withLock { DockerDmgProtocol.urls.first })
        #expect(url.host == "desktop.docker.com" && url.path.hasSuffix("/Docker.dmg") && url.scheme == "https")
        #expect(s.hdiutilLog.contains("attach -nobrowse -readonly -noautoopen -mountpoint"))
        #expect(s.hdiutilLog.contains("detach -force"))
        #expect(try leftovers(s).isEmpty, "the download and the mount point are removed")

        // Already installed: nothing is downloaded again.
        await i.install()
        if case .failed(let m) = i.phase { #expect(m.contains("already")) } else { Issue.record("expected a failure") }
        #expect(DockerDmgProtocol.lock.withLock { DockerDmgProtocol.urls.count } == 1)
    }

    @Test @MainActor func anUnsignedDownloadIsNeverInstalled() async throws {
        let s = try setup()
        let i = installer(s, signed: false)
        await i.install()
        guard case .failed(let m) = i.phase else { Issue.record("expected a failure"); return }
        #expect(m.contains("not signed by Docker"))
        #expect(!FileManager.default.fileExists(atPath: s.applications.appendingPathComponent("Docker.app").path))
        #expect(s.hdiutilLog.contains("detach -force"), "unmounted even when the check fails")
        #expect(try leftovers(s).isEmpty)
    }

    @Test @MainActor func aFailedDownloadStopsBeforeMounting() async throws {
        let s = try setup(status: 404)
        let i = installer(s, signed: true)
        await i.install()
        guard case .failed(let m) = i.phase else { Issue.record("expected a failure"); return }
        #expect(m.contains("404"))
        #expect(s.hdiutilLog.isEmpty)
        #expect(try leftovers(s).isEmpty)
    }

    @Test @MainActor func aCopyThatFailsHalfwayLeavesNoDockerApp() async throws {
        let s = try setup(unreadableFile: true)
        let i = installer(s, signed: true)
        await i.install()
        guard case .failed(let m) = i.phase else { Issue.record("expected a failure, got \(i.phase)"); return }
        #expect(m.contains("Could not copy"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.applications.path).isEmpty,
                "no Docker.app and no partial copy in Applications")
        #expect(s.hdiutilLog.contains("detach -force"))
    }

    @Test @MainActor func anOversizedDownloadIsRefusedBeforeMounting() async throws {
        let s = try setup(contentLength: "\(DockerDesktopInstaller.maxDownloadBytes + 1)")
        let i = installer(s, signed: true)
        await i.install()
        guard case .failed(let m) = i.phase else { Issue.record("expected a failure, got \(i.phase)"); return }
        #expect(m.contains("larger than"))
        #expect(s.hdiutilLog.isEmpty)
        #expect(try leftovers(s).isEmpty)
    }

    @Test func onlyDockerIncSignaturesPass() throws {
        let app = TestTemp.root.appendingPathComponent("fake-\(UUID().uuidString)/Docker.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("not signed".utf8).write(to: app.appendingPathComponent("Info.plist"))
        #expect(!DockerDesktopInstaller.isSignedByDocker(app.deletingLastPathComponent()))
        #expect(!DockerDesktopInstaller.isSignedByDocker(URL(fileURLWithPath: "/nonexistent/Docker.app")))
        #expect(DockerDesktopInstaller.teamIdentifier == "9BNSXJN65R")
    }
}
