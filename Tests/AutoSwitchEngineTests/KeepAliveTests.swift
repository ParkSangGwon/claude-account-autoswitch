import XCTest
@testable import AutoSwitchEngine
@testable import AutoSwitchCore

final class KeepAliveTests: XCTestCase {
    /// Accounts plus what the engine already knows about their windows: an account with no session
    /// reading is one whose five-hour window has rolled over, which is what keep-alive looks for.
    private func engine(_ accounts: [AccountRecord], on: Bool = true, observed: [AccountID: Windows] = [:]) throws -> Engine {
        var c = testConfiguration(accounts: accounts)
        c.quota.keepSessionOpen = on
        c.observed = Configuration.Observed(accounts: observed.map { .init(id: $0.key, windows: $0.value) })
        return Engine(store: try temporaryStore(c), version: "t")
    }

    private func windows(session: (used: Double, resetsIn: TimeInterval)? = nil, weekly: (used: Double, resetsIn: TimeInterval)? = nil) -> Windows {
        var w = Windows()
        if let session { w[.session] = WindowReading(used: session.used, resetsAt: Date().addingTimeInterval(session.resetsIn), seenAt: Date()) }
        if let weekly { w[.weekly] = WindowReading(used: weekly.used, resetsAt: Date().addingTimeInterval(weekly.resetsIn), seenAt: Date()) }
        return w
    }

    func testAClosedWindowIsOpenedAndTheReplyFillsIt() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let engine = try engine([oauthAccount("a")])
        try await engine.load()
        await engine.keepSessionsOpen()
        XCTAssertEqual(fake.pings, ["Bearer token-a"], "one request, on that account's own token")
        let after = await engine.state()
        let session = try XCTUnwrap(after.accounts[0].windows[.session], "the reply's headers opened the window")
        XCTAssertEqual(try XCTUnwrap(session.resetsAt).timeIntervalSinceNow, 5 * 3600, accuracy: 60)
        XCTAssertEqual(after.keepAlive.enabled, true)
        XCTAssertNotNil(after.keepAlive.lastOpenedAt)
        XCTAssertNil(after.keepAlive.lastError)
        // The window is open now, so the next pass has nothing to do.
        await engine.keepSessionsOpen()
        XCTAssertEqual(fake.pings.count, 1)
    }

    func testAnOpenWindowIsLeftAlone() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let engine = try engine([oauthAccount("a")], observed: [AccountID(rawValue: "id-a"): windows(session: (0.2, 3600))])
        try await engine.load()
        await engine.keepSessionsOpen()
        XCTAssertEqual(fake.pings, [])
    }

    func testTheToggleIsWhatSendsAnything() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let engine = try engine([oauthAccount("a")], on: false)
        try await engine.load()
        await engine.keepSessionsOpen()
        XCTAssertEqual(fake.pings, [], "off means the app sends nothing on the user's account")
        let state = await engine.state()
        XCTAssertFalse(state.keepAlive.enabled)
        try await engine.update { $0.quota.keepSessionOpen = true }
        await engine.keepSessionsOpen()
        XCTAssertEqual(fake.pings, ["Bearer token-a"])
    }

    /// Every reason an account cannot take a request is a reason not to open a window for it — a
    /// fresh five hours behind a spent week is five hours nobody can use.
    func testAnAccountThatCannotServeIsNotWokenUp() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let spentWeek = oauthAccount("week")
        let off = oauthAccount("off", enabled: false)
        var held = oauthAccount("held")
        held.skipUntil = Date().addingTimeInterval(3600)
        let key = AccountRecord(id: AccountID(rawValue: "id-key"), label: "key", credential: .apiKey("sk-ant-api03-x"))
        let engine = try engine([spentWeek, off, held, key], observed: [spentWeek.id: windows(weekly: (1.0, 86_400))])
        try await engine.load()
        await engine.keepSessionsOpen()
        XCTAssertEqual(fake.pings, [], "spent week, switched off, held aside, and an API key with no five-hour window")
    }

    func testAFailedTryIsNotRepeatedEveryTick() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        fake.pingStatus = 500
        let engine = try engine([oauthAccount("a")])
        try await engine.load()
        await engine.keepSessionsOpen()
        XCTAssertEqual(fake.pings.count, 1)
        let failed = await engine.state()
        XCTAssertEqual(failed.keepAlive.lastError, "a: " + L("Anthropic answered HTTP %d", 500))
        XCTAssertNil(failed.keepAlive.lastOpenedAt)

        await engine.keepSessionsOpen()
        XCTAssertEqual(fake.pings.count, 1, "a minute later the window is still closed, but the try is not repeated")

        fake.pingStatus = 200
        await engine.keepSessionsOpen(now: Date().addingTimeInterval(Engine.keepAliveRetry + 1))
        XCTAssertEqual(fake.pings.count, 2, "after the retry gap it tries again")
        let ok = await engine.state()
        XCTAssertNil(ok.keepAlive.lastError)
        XCTAssertNotNil(ok.accounts[0].windows[.session])
    }

    /// A reset an hour out is not worth waking for sooner; one seconds away is worth waking for then.
    func testTheNextPassWaitsForTheSoonestReset() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let hours = try engine([oauthAccount("a")], observed: [AccountID(rawValue: "id-a"): windows(session: (0.2, 3600))])
        try await hours.load()
        let far = await hours.keepSessionsOpen()
        XCTAssertEqual(far, Engine.keepAliveTick)

        let soon = try engine([oauthAccount("b")], observed: [AccountID(rawValue: "id-b"): windows(session: (0.2, 10))])
        try await soon.load()
        let near = await soon.keepSessionsOpen()
        XCTAssertEqual(near, 10, accuracy: 2)
        XCTAssertEqual(fake.pings, [])
    }
}
