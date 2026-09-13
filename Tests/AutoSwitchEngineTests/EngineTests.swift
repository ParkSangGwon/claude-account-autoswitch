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

    func testSwitchingToAWorseRankSaysTheBetterOneStillTakesTheRequest() async throws {
        let engine = Engine(store: try temporaryStore(testConfiguration(accounts: [oauthAccount("alice", rank: 0), oauthAccount("bob", rank: 5)])), version: "t")
        try await engine.load()
        let outcome = await engine.switchTo(AccountID(rawValue: "id-bob"))
        XCTAssertEqual(outcome.kind, .warn)
        XCTAssertEqual(outcome.text, "switched to bob, but alice has a better priority and takes the next request")
        let s = await engine.state()
        XCTAssertEqual(s.label(s.current), "bob")
        XCTAssertEqual(s.label(s.next), "alice", "what the toast just said")
    }

    func testSwitchingToTheBestRankIsPlainlyOK() async throws {
        let engine = Engine(store: try temporaryStore(testConfiguration(accounts: [oauthAccount("alice", rank: 0), oauthAccount("bob", rank: 5)])), version: "t")
        try await engine.load()
        _ = await engine.switchTo(AccountID(rawValue: "id-bob"))
        let outcome = await engine.switchTo(AccountID(rawValue: "id-alice"))
        XCTAssertEqual(outcome.kind, .ok)
        XCTAssertEqual(outcome.text, "switched to alice")
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

    func testAStoredObservationKeepsASpentAccountOutOfTheFirstRequest() async throws {
        var c = testConfiguration(accounts: [oauthAccount("alice", rank: 0), oauthAccount("bob", rank: 1)])
        var spent = Windows()
        spent[.weekly] = WindowReading(used: 0.99, resetsAt: Date().addingTimeInterval(3600), seenAt: Date())
        c.observed = Configuration.Observed(lastActive: AccountID(rawValue: "id-bob"),
                                           accounts: [.init(id: AccountID(rawValue: "id-alice"), windows: spent)])
        let engine = Engine(store: try temporaryStore(c), version: "t")
        try await engine.load()
        let s = await engine.state()
        XCTAssertEqual(s.label(s.current), "bob", "the account the last run left off on")
        XCTAssertEqual(s.label(s.next), "bob", "alice is known to be spent, so nothing lands there first")
        XCTAssertNotNil(s.account(AccountID(rawValue: "id-alice"))?.blocker)
    }

    func testAnObservationPastItsResetIsForgottenSoThePreferredAccountComesBack() async throws {
        var c = testConfiguration(accounts: [oauthAccount("alice", rank: 0), oauthAccount("bob", rank: 1)])
        var stale = Windows()
        stale[.weekly] = WindowReading(used: 0.99, resetsAt: Date().addingTimeInterval(-60), seenAt: Date().addingTimeInterval(-7200))
        c.observed = Configuration.Observed(lastActive: AccountID(rawValue: "id-bob"),
                                            accounts: [.init(id: AccountID(rawValue: "id-alice"), windows: stale)])
        let engine = Engine(store: try temporaryStore(c), version: "t")
        try await engine.load()
        let s = await engine.state()
        XCTAssertNil(s.account(AccountID(rawValue: "id-alice"))?.blocker, "the window rolled over while the app was closed")
        XCTAssertEqual(s.label(s.next), "alice", "the better rank takes the next request again")
    }

    func testAnObservationForAnAccountThatIsGoneIsIgnored() async throws {
        var c = testConfiguration(accounts: [oauthAccount("alice")])
        c.observed = Configuration.Observed(lastActive: AccountID(rawValue: "id-carol"), accounts: [])
        let engine = Engine(store: try temporaryStore(c), version: "t")
        try await engine.load()
        let s = await engine.state()
        XCTAssertEqual(s.label(s.current), "alice")
    }

    func testStoppingWritesWhatWasLearnedBackToTheDocument() async throws {
        let store = try temporaryStore(testConfiguration(accounts: [oauthAccount("alice")]))
        let engine = Engine(store: store, version: "t")
        try await engine.load()
        await engine.seedDemoWindows()
        await engine.stop()
        let saved = try store.load()
        XCTAssertEqual(saved.observed.lastActive?.rawValue, "id-alice")
        XCTAssertNotNil(saved.observed.windows(of: AccountID(rawValue: "id-alice"))?[.weekly])
    }

    func testACursorSettledOnLaunchIsWrittenWithoutWaitingForAQuit() async throws {
        var c = testConfiguration(accounts: [oauthAccount("alice", rank: 0), oauthAccount("bob", rank: 1)])
        var spent = Windows()
        spent[.weekly] = WindowReading(used: 0.99, resetsAt: Date().addingTimeInterval(3600), seenAt: Date())
        c.observed = Configuration.Observed(lastActive: AccountID(rawValue: "id-alice"),
                                            accounts: [.init(id: AccountID(rawValue: "id-alice"), windows: spent)])
        let store = try temporaryStore(c)
        let engine = Engine(store: store, version: "t")
        try await engine.load()
        XCTAssertEqual(try store.load().observed.lastActive?.rawValue, "id-bob", "the launch moved off the spent account and said so")
    }

    func testAManualSwitchIsRememberedForTheNextLaunch() async throws {
        let store = try temporaryStore(testConfiguration(accounts: [oauthAccount("alice", rank: 0), oauthAccount("bob", rank: 1)]))
        let engine = Engine(store: store, version: "t")
        try await engine.load()
        _ = await engine.switchTo(AccountID(rawValue: "id-bob"))
        XCTAssertEqual(try store.load().observed.lastActive?.rawValue, "id-bob")
    }

    func testAnUnreadableDocumentIsNeverOverwritten() async throws {
        let store = try temporaryStore(testConfiguration(accounts: [oauthAccount("alice"), oauthAccount("bob")]))
        let intact = try Data(contentsOf: store.path)
        try Data(#"{"accounts": "not a list"}"#.utf8).write(to: store.path)

        let engine = Engine(store: store, version: "t")
        do {
            try await engine.load()
            XCTFail("loading a broken document should throw")
        } catch let e as ConfigError {
            if case .malformed = e {} else { XCTFail("\(e)") }
        }
        let failure = await engine.loadFailure
        XCTAssertNotNil(failure, "the engine remembers it never read the file")

        // Every write path the settings screens reach refuses while that stands.
        do {
            try await engine.update { $0.rotation.switchAt = 0.5 }
            XCTFail("a write should be refused")
        } catch let e as EngineError {
            XCTAssertEqual(e, .configUnreadable)
        }
        _ = await engine.switchTo(AccountID(rawValue: "id-alice"))
        await engine.stop()
        XCTAssertEqual(try Data(contentsOf: store.path), Data(#"{"accounts": "not a list"}"#.utf8),
                       "the broken file is left exactly as it was, tokens and all")

        // Fixing the file by hand and reloading clears the refusal.
        try intact.write(to: store.path)
        let added = try await engine.reloadFromDisk()
        XCTAssertEqual(added, 2)
        let cleared = await engine.loadFailure
        XCTAssertNil(cleared)
        try await engine.update { $0.rotation.switchAt = 0.5 }
        XCTAssertEqual(try store.load().rotation.switchAt, 0.5)
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
