import Foundation
import Testing
@testable import Atlas

/// Counts the Keychain calls a test double receives.
final class CountingSecretStore: SecretStore {
    private let inner = InMemorySecretStore()
    private(set) var gets = 0, sets = 0
    func set(_ secret: String, for account: String) throws { sets += 1; try inner.set(secret, for: account) }
    func get(_ account: String) -> String? { gets += 1; return inner.get(account) }
    func delete(_ account: String) { inner.delete(account) }
}

/// Pages used to load everything from AWS each time they were opened.
@MainActor
struct ResponseCacheTests {
    private func makeState(_ secrets: SecretStore = InMemorySecretStore()) throws -> AppState {
        let folder = TestTemp.root.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(store: AccountStore(folder: folder), secrets: secrets)
        try state.addAccount(name: "Prod", accessKeyId: "AKIAPROD", secret: "s", region: "eu-west-1")
        try state.addAccount(name: "Dev", accessKeyId: "AKIADEV", secret: "d", region: "eu-west-1")
        return state
    }

    @Test func aFreshValueIsShownWithoutFetchingAgain() async throws {
        let state = try makeState()
        var fetches = 0, shown: [Int] = []
        func load(force: Bool = false) async throws {
            try await state.cached("ec2", force: force, show: { shown.append($0) }) { fetches += 1; return fetches }
        }
        try await load()
        try await load()
        #expect(fetches == 1 && shown == [1, 1])
        try await load(force: true)
        #expect(fetches == 2 && shown == [1, 1, 1, 2], "force shows the cached value, then the new one")
        state.refresh()
        try await load()
        #expect(fetches == 3, "Refresh makes the cache stale")
    }

    @Test func entriesAreKeptPerAccountAndRegionAndExpire() async throws {
        let state = try makeState()
        var fetches = 0
        func load() async throws -> Int {
            var value = 0
            try await state.cached("s3", show: { value = $0 }) { fetches += 1; return fetches }
            return value
        }
        #expect(try await load() == 1)
        state.region = "us-east-1"
        #expect(try await load() == 2)
        state.region = "eu-west-1"
        #expect(try await load() == 1)
        let dev = try #require(state.accounts.first { $0.name == "Dev" })
        state.setActive(dev.id)
        #expect(try await load() == 3)
        state.cache.ttl = 0
        #expect(try await load() == 4, "older than the ttl")
        state.removeAccount(dev.id)
        #expect(state.cache.count == 2, "a removed account's entries go")
    }

    @Test func aFailedFetchKeepsTheCachedValue() async throws {
        let state = try makeState()
        struct Boom: Error {}
        var shown: [Int] = []
        try await state.cached("iam", show: { shown.append($0) }) { 7 }
        await #expect(throws: Boom.self) {
            try await state.cached("iam", force: true, show: { shown.append($0) }) { () async throws -> Int in throw Boom() }
        }
        #expect(shown == [7, 7])
        try await state.cached("iam", show: { shown.append($0) }) { 8 }
        #expect(shown == [7, 7, 7], "still cached and fresh")
    }

    @Test func clientsAreMadeOnceInsteadOfReadingTheKeychainOnEveryRender() throws {
        let secrets = CountingSecretStore()
        let state = try makeState(secrets)
        let before = secrets.gets
        let account = try #require(state.activeAccount)
        let a = state.client(accountId: account.id, region: "eu-west-1")
        for _ in 0..<20 { _ = state.client(accountId: account.id, region: "eu-west-1"); _ = state.client }
        #expect(a != nil && secrets.gets == before + 1)
        #expect(state.client(accountId: "missing", region: "eu-west-1") == nil)
    }
}

/// Every change of a stack (a run starting, a status, a line flush) saved all stacks and wrote every variable to the
/// Keychain and read the output key again.
struct StackStoreSaveTests {
    @Test func savingWritesOnlyWhatChanged() throws {
        let secrets = CountingSecretStore()
        let folder = TestTemp.root.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        let store = StackStore(folder: folder, secrets: secrets)
        var s = StackEntry(name: "s", projectPath: "/tmp/s", accountId: "a", region: "eu-west-1")
        s.envVars = [StackEnvVar(tfVarName: "db", envKey: "DB", value: "one", resourceType: "aws_db_instance", resourceName: "db",
                                sourceFile: "rds.tf")]
        s.runs = [StackRun(type: .plan, status: .success, trigger: "manual", completedAt: Date(), output: "done")]
        store.save([s])
        let (gets, sets) = (secrets.gets, secrets.sets)
        #expect(sets == 2, "the output key and the variable")
        for _ in 0..<10 { store.save([s]) }
        #expect(secrets.sets == sets && secrets.gets == gets, "unchanged: no Keychain calls")
        s.envVars[0].value = "two"
        store.save([s])
        #expect(secrets.sets == sets + 1)

        let loaded = StackStore(folder: folder, secrets: secrets).load()
        #expect(loaded.first?.envVars.first?.value == "two")
        #expect(loaded.first?.runs.first?.output == "done")
    }
}
