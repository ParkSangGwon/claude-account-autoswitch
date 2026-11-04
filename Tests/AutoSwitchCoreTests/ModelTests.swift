import XCTest
@testable import AutoSwitchCore

final class ModelTests: XCTestCase {
    func testPlanFromClaudesOwnWords() {
        // Ultra still reports the tier of the plan it replaced.
        XCTAssertEqual(Plan(tierText: "default_claude_max_20x", seatText: nil), .ultra)
        XCTAssertEqual(Plan(tierText: "default_claude_max_5x", seatText: nil), .max)
        XCTAssertEqual(Plan(tierText: "default_claude_ultra", seatText: nil), .ultra)
        XCTAssertEqual(Plan(tierText: "default_claude_max_5x", seatText: "team_premium"), .team(multiplier: 5))
        XCTAssertEqual(Plan(tierText: "default", seatText: nil), .pro)
        XCTAssertEqual(Plan(tierText: "default_claude_pro", seatText: nil), .pro)
        XCTAssertEqual(Plan(tierText: "default_claude_xyz", seatText: nil), .unknown, "a tier nobody has seen is not guessed to be Pro")
        XCTAssertEqual(Plan(tierText: nil, seatText: "team_standard"), .team(multiplier: 1))
        XCTAssertEqual(Plan(tierText: nil, seatText: nil), .unknown)
        XCTAssertEqual(Plan.ultra.weight, 10)
        XCTAssertEqual(Plan.max.weight, 5)
        XCTAssertEqual(Plan.pro.weight, 1)
        XCTAssertNil(Plan.unknown.weight)
        XCTAssertEqual(Plan.ultra.badge, "Ultra")
        XCTAssertEqual(Plan.max.badge, "Max")
        XCTAssertEqual(Plan.team(multiplier: 1).badge, "Team")
        XCTAssertEqual(Plan.team(multiplier: 20).badge, "Team 20x")
        XCTAssertFalse(Plan.pro.includesFable)
        XCTAssertTrue(Plan.max.includesFable)
        XCTAssertTrue(Plan.ultra.includesFable)
    }

    /// A refusal goes with the five-hour reading that carries it; without a five-hour window only the TTL ends it.
    func testARefusalOnAnAccountWithNoFiveHourLimitLastsItsTTL() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var limited = Windows()
        limited.refusedAt = now
        limited.sweep(now: now)
        XCTAssertNil(limited.refusedAt, "no five-hour reading left to carry it")

        var ultra = Windows()
        ultra.sessionless = true
        ultra[.weekly] = WindowReading(used: 0.5, resetsAt: now.addingTimeInterval(86_400))
        ultra.refusedAt = now
        ultra.sweep(now: now.addingTimeInterval(60))
        XCTAssertEqual(ultra.refusedAt, now, "still refused on the next sweep")
        ultra.sweep(now: now.addingTimeInterval(Windows.refusalTTL + 1))
        XCTAssertNil(ultra.refusedAt)
    }

    func testFiveHourLimitIsAboutSubscriptionsThatStillHaveOne() {
        let ultra = Fixture.account("u", weekly: 0.2, sessionless: true)
        XCTAssertFalse(Fixture.state([ultra]).hasFiveHourLimit)
        XCTAssertFalse(Fixture.state([ultra, Fixture.account("key", kind: .apiKey)]).hasFiveHourLimit, "an API key has no five-hour window either")
        XCTAssertTrue(Fixture.state([ultra, Fixture.account("m", plan: .max, session: 0.1)]).hasFiveHourLimit)
        XCTAssertTrue(Fixture.state([Fixture.account("new")]).hasFiveHourLimit, "not known to be without one until a probe says so")
        XCTAssertFalse(Fixture.state([]).hasFiveHourLimit)
    }

    func testFamilyWindows() {
        XCTAssertEqual(WindowKind.weekly(for: "claude-fable-5-1"), .weeklyFable)
        XCTAssertEqual(WindowKind.weekly(for: "claude-sonnet-4-6"), .weeklySonnet)
        XCTAssertEqual(WindowKind.weekly(for: "claude-opus-5"), .weekly)
        XCTAssertEqual(WindowKind.weekly(for: nil), .weekly)
        XCTAssertEqual(WindowKind.session.length, 5 * 3600)
        XCTAssertEqual(WindowKind.weeklyFable.family, .fable)
        XCTAssertNil(WindowKind.weekly.family)
        XCTAssertEqual(WindowKind.session.tag, "5h")
        XCTAssertEqual(WindowKind.weeklySonnet.tag, "S7")
    }

    func testSweepForgetsExpiredWindowsAndStaleRefusals() {
        let now = Fixture.now
        var w = Windows()
        w[.session] = WindowReading(used: 0.9, resetsAt: now.addingTimeInterval(-1))
        w[.weekly] = WindowReading(used: 0.4, resetsAt: now.addingTimeInterval(3600))
        w.refusedAt = now.addingTimeInterval(-3600)
        w.tokens = Meter(limit: 100, remaining: 10); w.metersResetAt = now.addingTimeInterval(-5)
        w.sweep(now: now)
        XCTAssertNil(w[.session])
        XCTAssertNotNil(w[.weekly])
        XCTAssertNil(w.refusedAt)
        XCTAssertNil(w.tokens)
        var fresh = Windows()
        fresh[.session] = WindowReading(used: 0.9, resetsAt: now.addingTimeInterval(60))
        fresh.refusedAt = now.addingTimeInterval(-60)
        fresh.sweep(now: now)
        XCTAssertNotNil(fresh.refusedAt, "a recent refusal on a live window stands")
    }

    func testMeterUsedFraction() {
        XCTAssertEqual(try XCTUnwrap(Meter(limit: 200, remaining: 50).used), 0.75, accuracy: 1e-9)
        XCTAssertNil(Meter(limit: 0, remaining: 0).used)
    }

    func testUsageCapPerWindow() {
        XCTAssertEqual(UsageCap.uniform(0.5).limit(for: .weekly), 0.5)
        let table = UsageCap.perWindow([.session: 0.8])
        XCTAssertEqual(table.limit(for: .session), 0.8)
        XCTAssertNil(table.limit(for: .weekly))
    }

    func testSameIdentity() {
        let a = AccountRecord(label: "a@x", organization: Organization(name: nil, id: "org-1"), claudeAccountID: "acct-1", credential: .apiKey("k"))
        let sameOrg = AccountRecord(label: "other", organization: Organization(name: nil, id: "org-1"), claudeAccountID: "acct-1", credential: .apiKey("k"))
        let otherOrg = AccountRecord(label: "a@x", organization: Organization(name: nil, id: "org-2"), claudeAccountID: "acct-1", credential: .apiKey("k"))
        let noOrg = AccountRecord(label: "zz", claudeAccountID: "acct-1", credential: .apiKey("k"))
        let byLabel = AccountRecord(label: "a@x", credential: .apiKey("k"))
        XCTAssertTrue(a.sameIdentity(as: sameOrg))
        XCTAssertFalse(a.sameIdentity(as: otherOrg))
        XCTAssertTrue(a.sameIdentity(as: noOrg), "an unknown organization does not split an account")
        XCTAssertTrue(byLabel.sameIdentity(as: a), "without a Claude id on one side, the label decides")
        XCTAssertTrue(byLabel.sameIdentity(as: AccountRecord(label: "a@x", credential: .apiKey("z"))))
    }

    func testBlockerWords() {
        XCTAssertEqual(Blocker.switchedOff.code, "off")
        XCTAssertTrue(Blocker.needsLogin.needsPerson)
        XCTAssertFalse(Blocker.windowFull(.session, resetsAt: nil).needsPerson)
        XCTAssertEqual(Blocker.coolingDown(until: Fixture.now).liftsAt, Fixture.now)
        XCTAssertEqual(Blocker.windowFull(.weekly, resetsAt: nil).text, "Weekly window at the switch threshold")
        XCTAssertEqual(Blocker.capped(.session).text, "usage cap reached on the session window")
    }
}
