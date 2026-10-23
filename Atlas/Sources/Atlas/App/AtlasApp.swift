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
                let ok = NSApp.windows.contains { $0.isVisible }
                print(ok ? "SMOKE TEST OK" : "SMOKE TEST FAILED: no visible window")
                exit(ok ? 0 : 1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `ATLAS_SMOKE_TEST=1` starts the app with throwaway storage and quits after checking the window.
enum SmokeTest {
    static let isEnabled = ProcessInfo.processInfo.environment["ATLAS_SMOKE_TEST"] == "1"
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent("atlas-smoke-\(UUID().uuidString)")
}

@main
struct AtlasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = SmokeTest.isEnabled
        ? AppState(store: AccountStore(folder: SmokeTest.folder), secrets: InMemorySecretStore())
        : AppState()
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
            CommandMenu("Go") {
                ForEach(Array(Page.allCases.enumerated()), id: \.element) { index, page in
                    Button(page.title) { state.page = page }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }
    }
}
