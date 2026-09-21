import XCTest
@testable import AutoSwitchCore

final class ConfigurationTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "autoswitch-config-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func entries() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func testDefaults() {
        let c = Configuration.defaults
        XCTAssertEqual(c.version, 1)
        XCTAssertEqual(c.listen.port, 10912)
        XCTAssertEqual(c.api.baseURL, "https://api.anthropic.com")
        XCTAssertEqual(c.rotation.switchAt, 0.98)
        XCTAssertFalse(c.rotation.spreadSessions)
        XCTAssertEqual(c.rotation.waitWhenExhaustedSeconds, 0)
        XCTAssertEqual(c.quota.refreshEverySeconds, 300)
        XCTAssertFalse(c.quota.keepSessionOpen)
        XCTAssertEqual(c.accounts, [])
        XCTAssertEqual(c.rotation.switchAt(.weeklyFable), 0.98)
    }

    func testRoundTripKeepsEverything() throws {
        var c = Configuration.defaults
        c.rotation.switchAtByWindow = [.weekly: 0.9]
        c.accounts = [
            AccountRecord(label: "ted", rank: 1, enabled: false, cap: .perWindow([.session: 0.5]), plan: .max(multiplier: 20), planText: "default_claude_max_20x",
                          organization: Organization(name: "Org", id: "org-1"), claudeAccountID: "acct-1",
                          credential: .oauth(OAuthTokens(access: "at", refresh: "rt", expiresAt: Date(timeIntervalSince1970: 1_800_000_000)))),
            AccountRecord(label: "key", credential: .apiKey("sk-ant-api03-x")),
        ]
        let data = try Configuration.encoder().encode(c)
        let back = try Configuration.decoder().decode(Configuration.self, from: data)
        XCTAssertEqual(back, c)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"switchAtByWindow\""))
        XCTAssertFalse(text.contains("unified5h"), "no wire-format names leak into the document")
    }

    func testMissingSectionsTakeDefaults() throws {
        let c = try Configuration.decoder().decode(Configuration.self, from: Data(#"{"listen":{"port":4000},"accounts":[]}"#.utf8))
        XCTAssertEqual(c.listen.port, 4000)
        XCTAssertEqual(c.rotation.switchAt, 0.98)
        XCTAssertEqual(c.quota.refreshEverySeconds, 300)
        XCTAssertEqual(c.version, 1)

        // A quota section written before keep-alive existed keeps its probe and takes the new default.
        let old = try Configuration.decoder().decode(Configuration.self, from: Data(#"{"quota":{"refreshEverySeconds":60}}"#.utf8))
        XCTAssertEqual(old.quota.refreshEverySeconds, 60)
        XCTAssertFalse(old.quota.keepSessionOpen)
    }

    func testOutOfRangePortFallsBack() {
        var c = Configuration.defaults
        c.listen.port = 70000
        XCTAssertEqual(c.effectivePort, 10912)
    }

    func testResolvePath() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(ConfigStore.resolvePath(env: [:], home: home).path, "/Users/someone/Library/Application Support/Claude AutoSwitch/config.json")
        XCTAssertEqual(ConfigStore.resolvePath(env: ["CLAUDE_AUTOSWITCH_CONFIG": "/x/y.json"], home: home).path, "/x/y.json")
    }

    func testSaveWrites0600AndLeavesNoTemp() throws {
        let store = ConfigStore(path: dir.appending(path: "config.json"))
        var c = Configuration.defaults
        c.accounts = [AccountRecord(label: "a", credential: .apiKey("secret"))]
        try store.save(c)
        XCTAssertEqual(try entries(), ["config.json"])
        let perms = try FileManager.default.attributesOfItem(atPath: store.path.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(try store.load(), c)
        c.rotation.switchAt = 0.5
        try store.save(c)
        XCTAssertEqual(try store.load().rotation.switchAt, 0.5)
        XCTAssertEqual(try entries(), ["config.json"], "the second write replaced the file in place")
    }

    func testMissingAndMalformedFilesAreDistinctErrors() throws {
        let store = ConfigStore(path: dir.appending(path: "config.json"))
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? ConfigError, .notFound(store.path.path)) }
        try Data("{not json".utf8).write(to: store.path)
        XCTAssertThrowsError(try store.load()) { if case .malformed = $0 as? ConfigError {} else { XCTFail("\($0)") } }
    }

    func testPerWindowThresholdsAreWrittenByNameAndOlderFilesStillRead() throws {
        var c = Configuration.defaults
        c.rotation.switchAtByWindow = [.weekly: 0.9, .session: 0.5]
        let text = String(decoding: try Configuration.encoder().encode(c), as: UTF8.self)
        XCTAssertTrue(text.contains("\"weekly\" : 0.9"), "written the way a person writes it:\n\(text)")
        XCTAssertEqual(try Configuration.decoder().decode(Configuration.self, from: Data(text.utf8)).rotation.switchAtByWindow, c.rotation.switchAtByWindow)

        // What Swift's own dictionary encoding produced before this: a flat array of key, value.
        let older = #"{"rotation":{"switchAt":0.98,"switchAtByWindow":["weekly",0.9],"spreadSessions":false,"waitWhenExhaustedSeconds":0}}"#
        let decoded = try Configuration.decoder().decode(Configuration.self, from: Data(older.utf8))
        XCTAssertEqual(decoded.rotation.switchAtByWindow, [.weekly: 0.9])

        let unknownWindow = #"{"rotation":{"switchAtByWindow":{"weekly":0.9,"monthly":0.4}}}"#
        let lenient = try Configuration.decoder().decode(Configuration.self, from: Data(unknownWindow.utf8))
        XCTAssertEqual(lenient.rotation.switchAtByWindow, [.weekly: 0.9], "a window nobody knows is skipped, not fatal")
        XCTAssertEqual(lenient.rotation.switchAt, 0.98, "the rest of the section keeps its defaults")
    }

    func testAParseFailureNamesTheKeyToGoAndLookAt() throws {
        let store = ConfigStore(path: dir.appending(path: "config.json"))
        try Data(#"{"listen":{"port":"ten thousand"}}"#.utf8).write(to: store.path)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual(($0 as? ConfigError)?.message, "The config is not valid: listen.port is not the shape the app expects")
        }
        try Data("{not json".utf8).write(to: store.path)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual(($0 as? ConfigError)?.message, "The config is not valid: The file is not valid JSON")
        }
    }

    func testWriteThroughASymlinkKeepsTheLink() throws {
        let real = dir.appending(path: "real.json")
        try Data("{}".utf8).write(to: real)
        let link = dir.appending(path: "config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try ConfigStore(path: link).save(Configuration.defaults)
        XCTAssertEqual(try entries(), ["config.json", "real.json"])
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try ConfigStore(path: real).load(), Configuration.defaults)
    }
}
