import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let folder = Snapshots.folder {
            Snapshots.render(to: folder)
            exit(0)
        }

        // CI smoke test: the app must start and open its main window, then quit.
        if SmokeTest.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for line in SmokeTest.selfChecks() { print(line) }
                let ok = NSApp.windows.contains { $0.isVisible }
                print(ok ? "SMOKE TEST OK" : "SMOKE TEST FAILED: no visible window")
                exit(ok ? 0 : 1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `ATLAS_SMOKE_TEST=1` starts the app with throwaway storage, checks in the release binary the code that
/// protects credentials and files, and quits after checking the window (scripts/check.sh --full).
@MainActor
enum SmokeTest {
    static let isEnabled = ProcessInfo.processInfo.environment["ATLAS_SMOKE_TEST"] == "1"
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-smoke-\(UUID().uuidString)")
    private static weak var state: AppState?

    static func makeState() -> AppState {
        let s = AppState(store: AccountStore(folder: folder), secrets: InMemorySecretStore())
        state = s
        return s
    }

    static func selfChecks() -> [String] {
        // AWS's own "get-vanilla" test vector.
        let signer = SigV4Signer(credentials: AWSCredentials(
            accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"))
        let req = signer.request(method: "GET", host: "example.amazonaws.com", encodedPath: "/", service: "service",
                                 region: "us-east-1", date: Date(timeIntervalSince1970: 1_440_938_160),
                                 includeContentHashHeader: false)
        let sigv4 = req.value(forHTTPHeaderField: "Authorization")?
            .hasSuffix("Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31") == true
        let hcl = HclGenerator.quote("${file(\"/etc/passwd\")}%{if 1}") == #""$${file(\"/etc/passwd\")}%%{if 1}""#
        let folder = URL(fileURLWithPath: "/tmp/atlas-downloads", isDirectory: true)
        let s3 = ["..", ".", "a/..", "../../x", ""].allSatisfy {
            S3Download.destination(forKey: $0, in: folder).deletingLastPathComponent().standardizedFileURL.path == folder.path
        }
        let ssm = (try? SsmService.commandScript(plugin: "/p", session: .init(sessionId: "s", streamUrl: "u", tokenValue: "'$(x)'"),
                                                 region: "us-east-1", instanceId: "i-0123456789abcdef0"))
            .map { $0.contains(#"'\''$(x)'\''"#) && !$0.contains("\"$(") } ?? false
            && (try? SsmService.commandScript(plugin: "/p", session: .init(sessionId: "s", streamUrl: "u", tokenValue: "t"),
                                              region: "us-east-1", instanceId: "i-1;rm -rf ~")) == nil
        return [
            "SigV4 reference signature: \(sigv4)",
            "HCL strings cannot interpolate: \(hcl)",
            "S3 downloads stay in the chosen folder: \(s3)",
            "SSM script quotes every argument: \(ssm)",
            "Secrets kept in memory only: \(state?.usesKeychain == false)",
        ]
    }
}

@main
struct AtlasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = SmokeTest.isEnabled ? SmokeTest.makeState() : AppState()
    @AppStorage("theme") private var theme: AppTheme = .system

    var body: some Scene {
        WindowGroup("Atlas") {
            MainView()
                .environmentObject(state)
                .preferredColorScheme(theme.colorScheme)
                .tint(Palette.accent)
                .frame(minWidth: 1100, minHeight: 680)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { state.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("Search Resources…") { state.showSearch = true }
                    .keyboardShortcut("k", modifiers: .command)
                Divider()
                Picker("Appearance", selection: $theme) {
                    ForEach(AppTheme.allCases) { Text($0.label).tag($0) }
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.checkNow() }
                    .disabled(!Updater.isInstalled)
            }
            CommandMenu("Go") {
                // ⌘1…⌘9 for the first nine pages; the rest are in the menu without a shortcut.
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    if index < 9 {
                        Button(page.title) { state.page = page }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    } else {
                        Button(page.title) { state.page = page }
                    }
                }
            }
        }
    }
}
