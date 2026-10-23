import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AtlasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @AppStorage("theme") private var theme: AppTheme = .system

    var body: some Scene {
        WindowGroup("Atlas") {
            MainView()
                .environmentObject(state)
                .preferredColorScheme(theme.colorScheme)
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
