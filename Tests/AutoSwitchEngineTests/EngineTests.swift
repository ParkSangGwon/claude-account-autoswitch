import XCTest
@testable import AutoSwitchEngine
@testable import AutoSwitchCore

func temporaryStore(_ configuration: Configuration? = nil) throws -> ConfigStore {
    let dir = FileManager.default.temporaryDirectory.appending(path: "autoswitch-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = ConfigStore(path: dir.appending(path: "config.json"))
    if let configuration { try store.save(configuration) }
    return store
}

func testConfiguration(accounts: [AccountRecord], port: Int = 0, probe: Int = 0, baseURL: String? = nil) -> Configuration {
    var c = Configuration.defaults
    c.accounts = accounts
    if port > 0 { c.listen.port = port }
    c.quota.refreshEverySeconds = probe
    if let baseURL { c.api.baseURL = baseURL }
    return c
}

func oauthAccount(_ label: String, rank: Int = 0, enabled: Bool = true, plan: Plan = .max(multiplier: 20), claudeID: String? = nil, expiresIn: TimeInterval = 3600) -> AccountRecord {
    AccountRecord(id: AccountID(rawValue: "id-\(label)"), label: label, rank: rank, enabled: enabled, plan: plan, claudeAccountID: claudeID,
                  credential: .oauth(OAuthTokens(access: "token-\(label)", refresh: "refresh-\(label)", expiresAt: Date().addingTimeInterval(expiresIn))))
}

final class EngineTests: XCTestCase {
    func testFirstLaunchWritesTheDefaultsAndReportsAnEmptyState() async throws {
        let store = try temporaryStore()
        let engine = Engine(store: store, version: "0.0.1")
        try await engine.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.path.path))
        XCTAssertEqual(try store.load(), Configuration.defaults)
        let s = await engine.state()
        XCTAssertEqual(s.accounts, [])
        XCTAssertNil(s.current)
        XCTAssertEqual(s.listener.version, "0.0.1")
        XCTAssertFalse(s.listener.isRunning)
    }

    func testAccountsBecomeStatusRowsWithACursorOnTheBestRank() async throws {
        let engine = Engine(store: try temporaryStore(testConfiguration(accounts: [oauthAccount("bob", rank: 1), oauthAccount("alice", rank: 0)])), version: "t")
        try await engine.load()
        let s = await engine.state()
        XCTAssertEqual(s.accounts.map(\.label), ["bob", "alice"])
        XCTAssertEqual(s.label(s.current), "alice", "the lowest rank is preferred")
        XCTAssertEqual(s.next, s.current)
        XCTAssertEqual(s.accounts[1].plan.badge, "Max 20x")
        XCTAssertTrue(s.accounts.allSatisfy { $0.blocker == nil })
    }

    func testSwitchMovesTheCursorAndReportsTheBlocker() async throws {
        let engine = Engine(store: try temporaryStore(testConfiguration(accounts: [oauthAccount("alice"), oauthAccount("bob", enabled: false)])), version: "t")
        try await engine.load()
        let outcome = await engine.switchTo(AccountID(rawValue: "id-bob"))
        XCTAssertEqual(outcome.kind, .warn)
        XCTAssertEqual(outcome.text, "switched to bob, but rotation will not use it: turned off in Settings")
        let s = await engine.state()
        XCTAssertEqual(s.label(s.current), "bob")
        XCTAssertEqual(s.label(s.next), "alice", "the next request lands where it can be served")
        let missing = await engine.switchTo(AccountID(rawValue: "nobody"))
        XCTAssertEqual(missing.kind, .error)
    }

    func testUpdatesApplyLiveAndAReloadSeesOutsideEdits() async throws {
        let store = try temporaryStore(testConfiguration(accounts: [oauthAccount("alice")]))
        let engine = Engine(store: store, version: "t")
        try await engine.load()
        try await engine.update { $0.rotation.switchAt = 0.5 }
        let updated = await engine.state()
        XCTAssertEqual(updated.rotation.switchAt, 0.5)
        XCTAssertEqual(try store.load().rotation.switchAt, 0.5)
        var outside = try store.load()
        outside.accounts.append(oauthAccount("carol"))
        try store.save(outside)
        let added = try await engine.reloadFromDisk()
        XCTAssertEqual(added, 1)
        let reloaded = await engine.state()
        XCTAssertEqual(reloaded.accounts.count, 2)
    }

    func testAReloadKeepsWhatWasLearned() async throws {
        let store = try temporaryStore(testConfiguration(accounts: [oauthAccount("alice")]))
        let engine = Engine(store: store, version: "t")
        try await engine.load()
        await engine.seedDemoWindows()
        try await engine.update { $0.rotation.switchAt = 0.9 }
        let s = await engine.state()
        XCTAssertNotNil(s.accounts[0].windows[.session], "windows survive a config change")
    }

    func testHealthAnswersOverHTTP() async throws {
        let port = Int.random(in: 20000..<40000)
        let engine = Engine(store: try temporaryStore(testConfiguration(accounts: [oauthAccount("alice")], port: port)), version: "0.0.1")
        try await engine.start()
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/_autoswitch/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try JSON.parse(data)
        XCTAssertEqual(json["ok"].bool, true)
        XCTAssertEqual(json["port"].int, port)
        XCTAssertEqual(json["accounts"].int, 1)
        XCTAssertEqual(json["version"].string, "0.0.1")
        let running = await engine.state()
        XCTAssertTrue(running.listener.isRunning)
        await engine.stop()
    }

    func testABusyPortIsReportedNotSwallowed() async throws {
        let port = Int.random(in: 20000..<40000)
        let first = Engine(store: try temporaryStore(testConfiguration(accounts: [], port: port)), version: "t")
        try await first.start()
        let second = Engine(store: try temporaryStore(testConfiguration(accounts: [], port: port)), version: "t")
        do {
            try await second.start()
            XCTFail("second bind should fail")
        } catch let e as EngineError {
            XCTAssertEqual(e, .portInUse(port))
        }
        await first.stop()
    }
}
