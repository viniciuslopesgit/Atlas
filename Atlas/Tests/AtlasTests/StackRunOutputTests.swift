import Foundation
import SwiftUI
import Testing
@testable import Atlas

/// A run's output (shown in its timeline) grows while the engine runs.
struct StackRunLiveOutputTests {
    @Test func runsKeepTheirOutputLineByLine() {
        var run = StackRun(type: .initialize, trigger: "manual")
        #expect(run.lineCount == 0)
        run.append(["▶ tofu init", "", "Initializing the backend..."])
        #expect(run.output == "▶ tofu init\n\nInitializing the backend...")
        #expect(StackRunType.initialize.label == "Init" && StackRunType.setup.label == "Container")
        #expect(StackRunStatus.failed.color == Palette.danger && StackRunStatus.running.color == Palette.accent)
    }

    /// The run timeline shows `lastRun`: its output has to grow while the engine is still running, not only at the end.
    @Test @MainActor func initOutputReachesTheLatestRunWhileItRuns() async throws {
        let dir = TestTemp.root.appendingPathComponent("runoutput-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("resource \"null\" \"x\" {}\n".utf8).write(to: dir.appendingPathComponent("main.tf"))
        let bin = dir.appendingPathComponent("terraform").path
        try Data("#!/bin/bash\necho \"Initializing the backend...\"\nsleep 1.5\necho \"Terraform has been successfully initialized!\"\n".utf8)
            .write(to: URL(fileURLWithPath: bin))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
        let store = StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore())
        let model = StacksModel(store: store, clientFor: { _ in nil }, makeCLI: { _ in TerraformCLI(binary: bin, timeout: 30) })
        let s = model.create(name: "live", folder: dir, accountId: "a", region: "eu-west-1")

        model.initialize(s.id)
        var live: StackRun?
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            if let run = model.stack(s.id)?.lastRun, run.output.contains("Initializing the backend") { live = run; break }
        }
        let running = try #require(live, "no output while the run was going")
        #expect(running.status == .running && running.type == .initialize)
        #expect(model.busy.contains(s.id))
        #expect(!running.output.contains("successfully initialized"))

        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        let done = try #require(model.stack(s.id)?.lastRun)
        #expect(done.status == .success)
        #expect(done.output.contains("successfully initialized"))
    }
}

/// Regression: a run's output was wrapped at a few characters ("successfull / y / initialized") in the timeline's
/// log box; terminal lines keep their length and the box scrolls sideways instead.
struct TerminalLinesTests {
    @Test @MainActor func linesDoNotWrapInANarrowWidth() {
        let line = "OpenTofu has been successfully initialized!"
        let one = NSHostingController(rootView: TerminalLines(lines: [IaCModel.Line(id: 0, text: line)]))
            .sizeThatFits(in: CGSize(width: 1000, height: 1000))
        let narrow = NSHostingController(rootView: TerminalLines(lines: [IaCModel.Line(id: 0, text: line)]))
            .sizeThatFits(in: CGSize(width: 120, height: 1000))
        #expect(narrow.height == one.height, "wrapped into \(narrow.height / one.height) lines")
    }
}
