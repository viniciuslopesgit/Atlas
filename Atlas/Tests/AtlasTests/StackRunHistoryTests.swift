import Foundation
import Testing
@testable import Atlas

struct StackRunPhaseTests {
    @Test func phasesSplitTheOutputAndTakeTheRunsEnd() throws {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var run = StackRun(type: .plan, trigger: "manual", startedAt: t0)
        run.begin("Preparing", at: t0)
        run.append(["▶ container", "ready"])
        run.begin("Planning", at: t0.addingTimeInterval(2))
        run.append(["▶ terraform plan", "", "Plan: 1 to add"])
        #expect(run.phases.map(\.firstLine) == [0, 2])
        #expect(run.phases[0].status == .success && run.phases[0].completedAt == t0.addingTimeInterval(2))
        #expect(run.phases[1].status == .running)

        run.finish(.failed, at: t0.addingTimeInterval(9))
        #expect(run.status == .failed && run.completedAt == t0.addingTimeInterval(9))
        #expect(run.phases.map(\.status) == [.success, .failed], "the phase that was going failed")
        let timeline = run.timeline
        #expect(timeline.map(\.phase.name) == ["Preparing", "Planning"])
        #expect(timeline.map(\.output) == ["▶ container\nready", "▶ terraform plan\n\nPlan: 1 to add"])
    }

    @Test func aPhaseWithNoOutputYetIsEmptyAndAnEmptyRunHasNoLines() {
        var run = StackRun(type: .initialize, trigger: "manual")
        #expect(run.lineCount == 0)
        run.begin("Preparing")
        run.begin("Initializing")
        #expect(run.phases.map(\.firstLine) == [0, 0])
        #expect(run.timeline.map(\.output) == ["", ""])
        run.append(["a"])
        #expect(run.timeline.map(\.output) == ["", "a"])
    }

    @Test func phasesFollowTheOutputWhenItsStartIsCut() {
        var run = StackRun(type: .apply, trigger: "manual")
        run.begin("Preparing")
        run.append(["prep"])
        run.begin("Applying")
        let line = String(repeating: "x", count: 99)
        for i in 0..<20_000 { run.append(["\(i) \(line)"]) }
        #expect(run.output.hasPrefix(StackRun.trimmedNotice))
        #expect(run.phases.map(\.firstLine) == [0, 0], "both started in the removed part: they begin at the notice")
        run.begin("Verifying")
        run.append(["verify"])
        let timeline = run.timeline
        #expect(timeline[2].output == "verify")
        #expect(timeline[1].output.hasSuffix("19999 \(line)"))
    }

    @Test func runsSavedBeforePhasesAreOnePhase() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","type":"plan","status":"success","trigger":"manual","startedAt":0,"completedAt":5}"#
        var run = try JSONDecoder().decode(StackRun.self, from: Data(json.utf8))
        run.output = "a\nb"
        #expect(run.phases.isEmpty)
        let timeline = run.timeline
        #expect(timeline.count == 1 && timeline[0].phase.name == "Planning" && timeline[0].phase.status == .success)
        #expect(timeline[0].output == "a\nb")
        #expect(StackRunType.setup.phaseName == "Preparing" && StackRunType.fixDrift.phaseName == "Applying")
        #expect(StackRunType.importResources.phaseName == "Importing" && StackRunType.initialize.phaseName == "Initializing")
        #expect(StackRunType.fix.phaseName == "Fixing" && StackRunType.apply.phaseName == "Applying")
    }

    @Test func clocksReadLikeARunTimer() {
        #expect(StackRun.clock(2) == "00:02")
        #expect(StackRun.clock(750) == "12:30")
        #expect(StackRun.clock(3723) == "1:02:03")
        #expect(StackRun.clock(-4) == "00:00")
    }
}

struct StackRunHistoryStoreTests {
    @Test func finishedRunsKeepTheirWholeOutputInAnEncryptedFile() throws {
        let folder = TestTemp.root.appendingPathComponent("history-\(UUID().uuidString)")
        let store = StackStore(folder: folder, secrets: InMemorySecretStore())
        var s = StackEntry(name: "prod", projectPath: "/tmp/prod", accountId: "a", region: "eu-west-1")
        var done = StackRun(type: .plan, trigger: "manual")
        done.begin("Planning")
        done.append((1...2_000).map { "line \($0) SECRET-PLAN-OUTPUT" })
        done.finish(.success, at: Date())
        var going = StackRun(type: .apply, trigger: "manual")
        going.append((1...400).map { "apply \($0)" })
        s.runs = [going, done]
        store.save([s])

        let file = store.runLogFile(s.id, done.id)
        let sealed = try String(contentsOf: file, encoding: .utf8)
        #expect(!sealed.contains("SECRET-PLAN-OUTPUT"), "the log file is encrypted")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let json = try String(contentsOf: folder.appendingPathComponent("stacks.json"), encoding: .utf8)
        #expect(!json.contains("SECRET-PLAN-OUTPUT") && json.contains("Planning"))
        #expect(!FileManager.default.fileExists(atPath: store.runLogFile(s.id, going.id).path), "a run still going is not filed")

        let loaded = try #require(store.load().first)
        let plan = try #require(loaded.runs.first { $0.id == done.id })
        #expect(plan.output.components(separatedBy: "\n").count == 2_000, "the whole output, not its last lines")
        #expect(plan.phases.map(\.name) == ["Planning"] && plan.phases[0].status == .success)
        let apply = try #require(loaded.runs.first { $0.id == going.id })
        #expect(apply.output.components(separatedBy: "\n").count == StackStore.maxOutputLines)

        // Written once: saving again does not rewrite it.
        try Data("kept".utf8).write(to: file)
        store.save([loaded])
        #expect(try String(contentsOf: file, encoding: .utf8) == "kept")
    }

    @Test func runsSavedWithTheirOutputInsideStacksJsonStillLoad() throws {
        let folder = TestTemp.root.appendingPathComponent("legacy-\(UUID().uuidString)")
        let secrets = InMemorySecretStore()
        let store = StackStore(folder: folder, secrets: secrets)
        var s = StackEntry(name: "old", projectPath: "/tmp/old", accountId: "a", region: "eu-west-1")
        s.runs = [StackRun(type: .plan, trigger: "manual", output: "old output")]
        store.save([s])  // still going: kept inline, as every run was before
        var json = try String(contentsOf: folder.appendingPathComponent("stacks.json"), encoding: .utf8)
        json = json.replacingOccurrences(of: "\"status\" : \"running\"", with: "\"status\" : \"success\"")
        try Data(json.utf8).write(to: folder.appendingPathComponent("stacks.json"))
        let run = try #require(store.load().first?.runs.first)
        #expect(run.output == "old output" && run.status == .success && run.completedAt == nil)
    }

    @Test @MainActor func runsRecordTheirPhasesAndOldRunsTheirLogFile() async throws {
        let dir = TestTemp.root.appendingPathComponent("phases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("resource \"null\" \"x\" {}\n".utf8).write(to: dir.appendingPathComponent("main.tf"))
        let bin = dir.appendingPathComponent("terraform").path
        try Data("#!/bin/bash\necho \"$1 output\"\n[ \"$1\" = apply ] && exit 1\nexit 0\n".utf8).write(to: URL(fileURLWithPath: bin))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin)
        let store = StackStore(folder: dir.appendingPathComponent("support"), secrets: InMemorySecretStore())

        // 50 finished runs on disk: the next one pushes the oldest out, with its log file.
        var s = StackEntry(name: "hist", projectPath: dir.path, accountId: "a", region: "eu-west-1")
        s.runs = (0..<50).map { i in
            var r = StackRun(type: .plan, trigger: "old \(i)", startedAt: Date(timeIntervalSince1970: Double(1_000 - i)))
            r.append(["old \(i)"])
            r.finish(.success, at: r.startedAt)
            return r
        }
        store.save([s])
        let oldest = try #require(s.runs.last)
        let other = s.runs[10]
        #expect(FileManager.default.fileExists(atPath: store.runLogFile(s.id, oldest.id).path))

        let model = StacksModel(store: store, clientFor: { _ in nil }, makeCLI: { _ in TerraformCLI(binary: bin, timeout: 30) })
        model.initialize(s.id)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        let initRun = try #require(model.stack(s.id)?.lastRun)
        #expect(initRun.type == .initialize && initRun.status == .success)
        #expect(initRun.phases.map(\.name) == ["Initializing"] && initRun.phases[0].status == .success)
        #expect(initRun.timeline[0].output.contains("init output"))
        #expect(model.stack(s.id)?.runs.count == 50)
        #expect(!FileManager.default.fileExists(atPath: store.runLogFile(s.id, oldest.id).path), "dropped with its run")
        #expect(FileManager.default.fileExists(atPath: store.runLogFile(s.id, other.id).path))
        #expect(FileManager.default.fileExists(atPath: store.runLogFile(s.id, initRun.id).path), "filed when it finished")

        let plans = model.planFiles(for: s).folder
        try PrivateFile.createFolder(plans)
        try Data("plan".utf8).write(to: plans.appendingPathComponent(StacksModel.planFile))
        model.apply(s.id)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        let applyRun = try #require(model.stack(s.id)?.lastRun)
        #expect(applyRun.status == .failed && applyRun.phases.map(\.status) == [.failed])
        #expect(applyRun.phases.map(\.name) == ["Applying"])

        model.checkDrift(s.id)
        for _ in 0..<300 where model.busy.contains(s.id) { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(model.stack(s.id)?.lastRun?.phases.map(\.name) == ["Checking drift"])
    }
}

struct StackRunViewTests {
    @Test func tabsListTheirKindOfRun() {
        let plan = StackRun(type: .plan, trigger: "manual"), apply = StackRun(type: .apply, trigger: "manual")
        let fix = StackRun(type: .fixDrift, trigger: "auto-fix"), initRun = StackRun(type: .initialize, trigger: "manual")
        let all = [plan, apply, fix, initRun]
        #expect(all.filter(StackRunScope.all.includes).count == 4)
        #expect(all.filter(StackRunScope.plans.includes).map(\.id) == [plan.id])
        #expect(all.filter(StackRunScope.applies.includes).map(\.id) == [apply.id, fix.id])
        #expect(StackRunScope.allCases.allSatisfy { !$0.emptyMessage.isEmpty })
    }

    @Test func theNewestAndFailedPhasesOpenFirst() {
        var run = StackRun(type: .importResources, trigger: "import")
        #expect(StackRunDetail.initiallyExpanded(run) == [0], "a run without phases shows its output")
        run.begin("Preparing state")
        run.begin("Initializing")
        run.begin("Importing")
        run.phases[1].status = .failed
        #expect(StackRunDetail.initiallyExpanded(run) == [1, 2])
        #expect(StackRunDetail.lines("").isEmpty && StackRunDetail.lines("a\nb").map(\.text) == ["a", "b"])
    }

    @Test func statusesReadLikeARunsState() {
        #expect([StackRunStatus.running, .success, .failed, .cancelled].map(\.label) == ["Running", "Finished", "Failed", "Cancelled"])
        #expect(Set([StackRunStatus.running, .success, .failed, .cancelled].map(\.icon)).count == 4)
    }

    @Test func downloadedLogsGetASafeNameWithTheRunsTime() {
        let run = StackRun(type: .plan, trigger: "manual", startedAt: Date(timeIntervalSince1970: 0))
        let name = LogExport.fileName(run, stackName: "omnium/../prod x")
        #expect(!name.contains("/") && !name.contains(" ") && name.hasSuffix(".log"))
        #expect(name.hasPrefix("omnium----prod-x-plan-"))
    }
}
