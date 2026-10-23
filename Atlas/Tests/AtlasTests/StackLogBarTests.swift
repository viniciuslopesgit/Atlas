import Foundation
import Testing
@testable import Atlas

struct StackLogBarTests {
    @Test func draggingUpMakesTheBarTallerWithinItsLimits() {
        #expect(StackLogBar.resized(from: 200, draggedBy: -50) == 250)
        #expect(StackLogBar.resized(from: 200, draggedBy: 60) == 140)
        #expect(StackLogBar.resized(from: 200, draggedBy: 1_000) == StackLogBar.heightRange.lowerBound)
        #expect(StackLogBar.resized(from: 200, draggedBy: -5_000) == StackLogBar.heightRange.upperBound)
        #expect(StackLogBar.heightRange.contains(StackLogBar.defaultHeight))
    }

    @Test func aRunOpensTheBarAndTheEndOfARunLeavesItAsItWas() {
        #expect(StackLogBar.isOpen(false, afterBusyChange: true))
        #expect(StackLogBar.isOpen(true, afterBusyChange: true))
        #expect(!StackLogBar.isOpen(false, afterBusyChange: false), "closed by the user, stays closed")
        #expect(StackLogBar.isOpen(true, afterBusyChange: false))
    }

    @Test func showsTheRunsOutputLineByLine() {
        #expect(StackLogBar.lines(nil).isEmpty)
        var run = StackRun(type: .initialize, trigger: "manual")
        #expect(StackLogBar.lines(run).isEmpty, "an empty run shows the placeholder, not one blank line")
        run.append(["▶ tofu init", "", "Initializing the backend..."])
        #expect(StackLogBar.lines(run).map(\.text) == ["▶ tofu init", "", "Initializing the backend..."])
        #expect(StackLogBar.lines(run).map(\.id) == [0, 1, 2])
        #expect(StackRunType.initialize.label == "Init" && StackRunType.setup.label == "Container")
        #expect(StackRunStatus.failed.color == Palette.danger && StackRunStatus.running.color == Palette.accent)
    }

    /// The bar shows `lastRun`: its output has to grow while the engine is still running, not only at the end.
    @Test @MainActor func initOutputReachesTheLatestRunWhileItRuns() async throws {
        let dir = TestTemp.root.appendingPathComponent("logbar-\(UUID().uuidString)", isDirectory: true)
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
        #expect(StackLogBar.lines(done).contains { $0.text.contains("successfully initialized") })
    }
}
