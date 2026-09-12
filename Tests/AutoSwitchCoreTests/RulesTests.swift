import XCTest
@testable import AutoSwitchCore

final class PaceTests: XCTestCase {
    let now = Fixture.now

    func testThresholdIsCriticalWhateverThePace() {
        XCTAssertEqual(Pace.severity(used: 0.98, resetsAt: now.addingTimeInterval(4 * 3600), length: 5 * 3600, threshold: 0.98, now: now), .critical)
    }

    func testLeadOverTheClockSetsTheSeverity() {
        // 20 % of the window elapsed.
        let reset = now.addingTimeInterval(4 * 3600)
        XCTAssertEqual(Pace.severity(used: 0.20, resetsAt: reset, length: 5 * 3600, threshold: 0.98, now: now), .calm)
        XCTAssertEqual(Pace.severity(used: 0.24, resetsAt: reset, length: 5 * 3600, threshold: 0.98, now: now), .brisk)
        XCTAssertEqual(Pace.severity(used: 0.34, resetsAt: reset, length: 5 * 3600, threshold: 0.98, now: now), .hot)
        XCTAssertEqual(Pace.severity(used: 0.50, resetsAt: reset, length: 5 * 3600, threshold: 0.98, now: now), .critical)
    }

    func testWithoutAClockPlainFillLevelsApply() {
        XCTAssertEqual(Pace.severity(used: 0.5, resetsAt: nil, length: 3600, threshold: 0.98, now: now), .calm)
        XCTAssertEqual(Pace.severity(used: 0.75, resetsAt: nil, length: nil, threshold: nil, now: now), .brisk)
        XCTAssertEqual(Pace.severity(used: 0.95, resetsAt: nil, length: nil, threshold: nil, now: now), .critical)
        XCTAssertEqual(Pace.plain(0.1), .calm)
    }
}

final class FormatTests: XCTestCase {
    let now = Fixture.now

    func testCountdown() {
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(3 * 3600 + 31 * 60), now: now), "3h31m")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(2 * 3600), now: now), "2h")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(3 * 86_400 + 12 * 3600), now: now), "3d12h")
        XCTAssertEqual(Format.countdown(now.addingTimeInterval(-1), now: now), "")
        XCTAssertEqual(Format.countdown(nil, now: now), "")
        XCTAssertEqual(Format.countdown(Date.distantFuture, now: now), "", "a broken clock is not a window")
    }

    func testDuration() {
        XCTAssertEqual(Format.duration(0.4), "1s")
        XCTAssertEqual(Format.duration(45), "45s")
        XCTAssertEqual(Format.duration(3 * 3600 + 31 * 60), "3h31m")
        XCTAssertEqual(Format.duration(.infinity), "-")
    }

    func testResetSentence() {
        L10n.activate("en")
        let cal = Calendar(identifier: .gregorian)
        let s = Format.resetSentence(now.addingTimeInterval(3 * 3600 + 31 * 60), style: .countdown, now: now, calendar: cal)
        XCTAssertEqual(s, "Resets in 3h 31m")
        XCTAssertEqual(Format.resetSentence(now.addingTimeInterval(-5), now: now, calendar: cal), "Reset overdue")
        XCTAssertEqual(Format.resetSentence(nil, now: now), "")
        XCTAssertTrue(Format.resetSentence(now.addingTimeInterval(600), style: .both, now: now, calendar: cal).hasPrefix("Resets in 10m ("))
    }

    func testPercents() {
        XCTAssertEqual(Format.percent(0.42), "42%")
        XCTAssertEqual(Format.percent(0.425), "42.5%")
        XCTAssertEqual(Format.percent(nil), "—")
        XCTAssertEqual(Format.percentInt(0.426), 43)
        XCTAssertEqual(Format.percentInt(.infinity), 0)
        XCTAssertEqual(Format.percentInt(1e300), 1_000_000)
        XCTAssertEqual(Format.safeInt(1e300), Int(1e15))
    }

    func testMoneyAndTags() {
        XCTAssertEqual(Format.money(minor: 1234, currency: "usd", exponent: 2), "$12.34")
        XCTAssertEqual(Format.money(minor: 500, currency: "EUR", exponent: 2), "EUR 5.00")
        XCTAssertEqual(Format.tag("alice@example.com"), "ali")
        XCTAssertEqual(Format.tag("ParkSangGwon"), "par")
        XCTAssertEqual(Format.tag("t-e"), "te")
    }
}

final class FleetTests: XCTestCase {
    let now = Fixture.now

    func testTotalsAreWeightedByPlan() throws {
        let s = Fixture.state([
            Fixture.account("big", plan: .max(multiplier: 20), session: 0.5, weekly: 0.2),
            Fixture.account("small", plan: .pro, session: 1.0, weekly: 0.8),
            Fixture.account("off", enabled: false, session: 1.0, blocker: .switchedOff),
            Fixture.account("mystery", plan: .unknown, session: 1.0),
        ])
        let five = try XCTUnwrap(Fleet.total(s, .session))
        XCTAssertEqual(five.used, (20 * 0.5 + 1 * 1.0) / 21, accuracy: 1e-9)
        XCTAssertEqual(five.knownAccounts, 2)
        XCTAssertEqual(five.capacity, 21)
        XCTAssertEqual(Fleet.unweighed(s).map(\.label), ["mystery"])
        XCTAssertNil(Fleet.total(s, .weeklyFable))
        XCTAssertEqual(try XCTUnwrap(Fleet.elapsedShare(s, .session, now: now)), 0.8, accuracy: 1e-9)
    }

    func testResetTimelineSkipsAFamilyThatRollsWithTheWeek() {
        let s = Fixture.state([
            Fixture.account("a", session: 0.5, sessionReset: 600, weekly: 0.2, fable: 0.3, blocker: .windowFull(.session, resetsAt: now.addingTimeInterval(600))),
            Fixture.account("b", session: 0.1, sessionReset: 7200, weekly: 0.9, weeklyReset: 3600),
        ])
        let entries = Fleet.resetTimeline(s, now: now)
        XCTAssertEqual(entries.map { "\($0.label)/\($0.kind.rawValue)" }, ["a/session", "b/weekly", "b/session", "a/weekly"])
        XCTAssertTrue(entries[0].freesCapacity)
        XCTAssertFalse(entries[1].freesCapacity)
    }
}

final class ExplainTests: XCTestCase {
    let now = Fixture.now

    func testSwitchCauseNamesTheBlockerThenTheRank() {
        let s = Fixture.state([Fixture.account("a", rank: 1, blocker: .windowFull(.session, resetsAt: now.addingTimeInterval(3600))), Fixture.account("b", rank: 0)], current: "a", next: "b")
        let cause = Explain.switchCause(from: Fixture.id("a"), to: Fixture.id("b"), state: s)
        XCTAssertEqual(cause, .blocked(.windowFull(.session, resetsAt: now.addingTimeInterval(3600))))
        XCTAssertEqual(cause?.text(from: "a", to: "b", at: now), "a: Session window at the switch threshold · resets in 1h")
        let healthy = Fixture.state([Fixture.account("a", rank: 1), Fixture.account("b", rank: 0)], current: "a", next: "b")
        XCTAssertEqual(Explain.switchCause(from: Fixture.id("a"), to: Fixture.id("b"), state: healthy), .outranked(newRank: 0, oldRank: 1))
        XCTAssertEqual(SwitchCause.outranked(newRank: 0, oldRank: 1).text(from: "a", to: "b", at: now), "b outranks a (priority 0 < 1)")
        XCTAssertEqual(SwitchCause.manual.text(from: "a", to: "b", at: now), "switched from the app")
    }

    func testNextRequestLine() throws {
        let s = Fixture.state([Fixture.account("a", rank: 0, sessions: 2), Fixture.account("b", rank: 1)], current: "a")
        let n = try XCTUnwrap(Explain.nextRequest(s, now: now))
        XCTAssertTrue(n.isCurrent)
        XCTAssertEqual(n.reason, "prio 0 · 2 sess")
        let moved = Fixture.state([Fixture.account("a", rank: 0, blocker: .coolingDown(until: now.addingTimeInterval(120))), Fixture.account("b", rank: 1)], current: "a", next: "b")
        let m = try XCTUnwrap(Explain.nextRequest(moved, now: now))
        XCTAssertFalse(m.isCurrent)
        XCTAssertTrue(m.reason.hasPrefix("a: cooling down after a 429"))
    }

    func testTargetsListFamiliesThenEverythingElse() {
        let s = Fixture.state([Fixture.account("a", session: 0.1, weekly: 0.1, fable: 0.99), Fixture.account("b", session: 0.1, weekly: 0.1, fable: 0.1)], current: "a")
        let rows = Explain.targets(s)
        XCTAssertEqual(rows.map(\.id), ["fable", "default"])
        XCTAssertEqual(rows[0].eligible, ["b"], "a's own Fable week is over the threshold")
        XCTAssertEqual(rows[0].ineligible, ["a"])
        XCTAssertTrue(rows[1].isCurrent)
        XCTAssertEqual(Explain.targets(Fixture.state([Fixture.account("a", session: 0.1)])), [], "no family windows, no card")
    }

    func testNoticesOnlyNameWhatNeedsAPerson() {
        let s = Fixture.state([
            Fixture.account("a", blocker: .needsLogin, health: .needsLogin),
            Fixture.account("b", enabled: false, blocker: .switchedOff),
            Fixture.account("c", blocker: .windowFull(.session, resetsAt: nil)),
        ], sessions: [Fixture.session("s-1", starved: 7), Fixture.session("s-2", starved: 2)])
        let notices = Explain.notices(s)
        XCTAssertEqual(notices.map(\.kind), ["starved-session", "account", "account"])
        XCTAssertEqual(notices[0].text, "Session claude-code s-1 has had 7 requests in a row come back with nothing — it is failing, not idle.")
        XCTAssertEqual(notices[1].text, "Account a needs a re-login.")
        XCTAssertEqual(notices[2].text, "Account b is disabled.")
        XCTAssertEqual(Explain.exhaustedReason(s), "every account is out of rotation")
        let stalled = Fixture.state([Fixture.account("a", blocker: .windowFull(.session, resetsAt: nil)), Fixture.account("b", blocker: .coolingDown(until: now))])
        XCTAssertEqual(Explain.exhaustedReason(stalled), "every account is over its quota threshold or in a rate-limit hold")
        XCTAssertTrue(stalled.isExhausted)
    }

    func testSwitchOutcomeWording() {
        XCTAssertEqual(SwitchOutcome.switched(to: "b", blocker: nil), SwitchOutcome(kind: .ok, text: "switched to b"))
        XCTAssertEqual(SwitchOutcome.switched(to: "b", blocker: .switchedOff).text, "switched to b, but rotation will not use it: turned off in Settings")
        XCTAssertEqual(SwitchOutcome.failed("no").kind, .error)
    }

    func testAliasesStayUnique() {
        let out = Explain.aliases(for: [(label: "alice@x.com", org: "A"), (label: "alice@y.com", org: "B"), (label: "bob@x.com", org: nil)])
        XCTAssertEqual(out["alice@x.com"], "alice (A)")
        XCTAssertEqual(out["alice@y.com"], "alice (B)")
        XCTAssertEqual(out["bob@x.com"], "bob")
        let numbered = Explain.aliases(for: [(label: "alice@x.com", org: nil), (label: "alice@y.com", org: nil)])
        XCTAssertEqual(numbered["alice@y.com"], "alice 2")
    }

    func testJournalKeepsFifty() {
        var j = Journal()
        for i in 0..<60 { j.append(SwitchEvent(at: now.addingTimeInterval(Double(i)), from: "a", to: "b", cause: .manual)) }
        XCTAssertEqual(j.events.count, Journal.capacity)
        XCTAssertEqual(j.latest.first?.at, now.addingTimeInterval(59))
        XCTAssertEqual(j.count(within: 5, now: now.addingTimeInterval(59)), 6)
        let data = try! JSONEncoder().encode(j)
        XCTAssertEqual(try! JSONDecoder().decode(Journal.self, from: data), j)
    }

    func testStateHelpers() {
        let s = Fixture.state([Fixture.account("b", rank: 1), Fixture.account("a", rank: 0, blocker: .drained, health: .drained)], current: "a", next: "b")
        XCTAssertEqual(s.byRank.map(\.label), ["a", "b"])
        XCTAssertTrue(s.currentMovedOn)
        XCTAssertFalse(s.isExhausted)
        XCTAssertEqual(s.label(Fixture.id("b")), "b")
        XCTAssertNil(s.account(labelled: "zz"))
    }
}
