import XCTest
@testable import AutoSwitchCore

final class AlertEngineTests: XCTestCase {
    let now = Fixture.now
    var prefs = AlertPrefs()

    override func setUp() { L10n.activate("en"); prefs = AlertPrefs(); prefs.accountLeft = true; prefs.accountBack = true }

    private func run(_ state: EngineState?, previous: EngineState? = nil, alertState: AlertState = AlertState(), reachable: Bool = true, appSwitchedTo: AccountID? = nil, at: Date? = nil) -> (alerts: [Alert], state: AlertState) {
        AlertEngine.evaluate(AlertInputs(previous: previous, state: state, reachable: reachable, appSwitchedTo: appSwitchedTo, now: at ?? now), state: alertState, prefs: prefs)
    }

    private func fleet(_ used: Double) -> EngineState {
        Fixture.state([Fixture.account("a", session: used, weekly: 0.1)], current: "a")
    }

    func testFirstEvaluationSeedsQuietly() {
        let (alerts, s) = run(Fixture.state([Fixture.account("a", session: 0.96, blocker: .needsLogin, health: .needsLogin)]))
        XCTAssertEqual(alerts, [])
        XCTAssertTrue(s.seeded)
        XCTAssertEqual(s.loginNeeded, ["id-a"])
        XCTAssertEqual(s.fired["fleet.5h"], [90, 95])
    }

    func testFleetLevelsFireOncePerCrossingWithHysteresis() {
        var s = run(fleet(0.70)).state
        var out = run(fleet(0.92), alertState: s); s = out.state
        XCTAssertEqual(out.alerts.map(\.id), ["fleet.5h.90"])
        XCTAssertEqual(out.alerts[0].title, "Fleet 5-hour usage at 92%")
        out = run(fleet(0.96), alertState: s); s = out.state
        XCTAssertEqual(out.alerts.map(\.id), ["fleet.5h.95"])
        out = run(fleet(0.93), alertState: s); s = out.state
        XCTAssertEqual(out.alerts, [], "still above 90, no re-fire")
        out = run(fleet(0.84), alertState: s); s = out.state
        out = run(fleet(0.91), alertState: s)
        XCTAssertEqual(out.alerts.map(\.id), ["fleet.5h.90"], "five points below re-arms the level")
    }

    func testRotationAlertNamesTheReasonAndSkipsTheAppsOwnSwitch() {
        let before = Fixture.state([Fixture.account("a", rank: 0), Fixture.account("b", rank: 1)], current: "a")
        let s = run(before).state
        let after = Fixture.state([Fixture.account("a", rank: 0, blocker: .windowFull(.session, resetsAt: now.addingTimeInterval(1800))), Fixture.account("b", rank: 1)], current: "a", next: "b")
        let out = run(after, previous: before, alertState: s)
        XCTAssertEqual(Set(out.alerts.map(\.kind)), [.accountLeft, .rotation])
        let rotation = try! XCTUnwrap(out.alerts.first { $0.kind == .rotation })
        XCTAssertEqual(rotation.title, "Rotated: a → b")
        XCTAssertEqual(rotation.body, "a: Session window at the switch threshold · resets in 30m")
        let manual = run(after, previous: before, alertState: s, appSwitchedTo: Fixture.id("b"))
        XCTAssertNil(manual.alerts.first { $0.kind == .rotation })
    }

    func testAccountLeavesAndReturns() {
        let s = run(Fixture.state([Fixture.account("a"), Fixture.account("b", rank: 1)], current: "a")).state
        let gone = run(Fixture.state([Fixture.account("a", blocker: .coolingDown(until: now.addingTimeInterval(60))), Fixture.account("b", rank: 1)], current: "a"), alertState: s)
        XCTAssertEqual(gone.alerts.map(\.id), ["acct.left.id-a"])
        XCTAssertEqual(gone.alerts[0].body, "cooling down after a 429 · 1m · resets in 1m")
        let back = run(Fixture.state([Fixture.account("a"), Fixture.account("b", rank: 1)], current: "a"), alertState: gone.state)
        XCTAssertEqual(back.alerts.map(\.id), ["acct.back.id-a"])
        XCTAssertEqual(back.alerts[0].body, "The hold cleared.")
        // Turning an account off is a person's choice, not rotation.
        let off = run(Fixture.state([Fixture.account("a", enabled: false, blocker: .switchedOff), Fixture.account("b", rank: 1)], current: "a"), alertState: back.state)
        XCTAssertEqual(off.alerts, [])
    }

    func testLoginProbeAndHold() {
        let s = run(Fixture.state([Fixture.account("a"), Fixture.account("b")])).state
        let login = run(Fixture.state([Fixture.account("a", blocker: .needsLogin, health: .needsLogin), Fixture.account("b", probeError: "401")]), alertState: s)
        XCTAssertEqual(Set(login.alerts.map(\.kind)), [.accountError, .probeFailed, .rotation], "a sign-in problem is announced once, not as ordinary rotation; the next request moving to b is")
        let hold = run(Fixture.state([Fixture.account("a", blocker: .windowFull(.session, resetsAt: nil)), Fixture.account("b", blocker: .coolingDown(until: now))]), alertState: login.state)
        let h = try! XCTUnwrap(hold.alerts.first { $0.kind == .hold })
        XCTAssertEqual(h.body, "every account is over its quota threshold or in a rate-limit hold")
        XCTAssertTrue(h.sound)
        let again = run(Fixture.state([Fixture.account("a", blocker: .windowFull(.session, resetsAt: nil)), Fixture.account("b", blocker: .coolingDown(until: now))]), alertState: hold.state)
        XCTAssertNil(again.alerts.first { $0.kind == .hold }, "announced once")
    }

    func testProxyDownAfterTwoMissesAndBackOnce() {
        prefs.proxyBack = true
        var s = run(nil, reachable: false).state
        XCTAssertFalse(s.announcedDown)
        var out = run(nil, alertState: s, reachable: false); s = out.state
        XCTAssertEqual(out.alerts.map(\.id), ["proxy.down"])
        out = run(nil, alertState: s, reachable: false); s = out.state
        XCTAssertEqual(out.alerts, [])
        out = run(Fixture.state([]), alertState: s, reachable: true)
        XCTAssertEqual(out.alerts.map(\.id), ["proxy.back"])
    }

    func testPauseMutesEverythingButHoldAndDown() {
        prefs.pausedUntil = now.addingTimeInterval(3600)
        let s = run(Fixture.state([Fixture.account("a")])).state
        let out = run(Fixture.state([Fixture.account("a", blocker: .windowFull(.session, resetsAt: nil))]), alertState: s)
        XCTAssertEqual(out.alerts.map(\.kind), [.hold])
    }

    func testOverageOncePerMonth() {
        let paid = Fixture.state([Fixture.account("a", overage: Overage(enabled: true, usedMinor: 1234, currency: "USD", exponent: 2))])
        let s = run(Fixture.state([Fixture.account("a")])).state
        let out = run(paid, alertState: s)
        XCTAssertEqual(out.alerts.map(\.kind), [.spend])
        XCTAssertEqual(out.alerts[0].body, "$12.34 used this month")
        XCTAssertEqual(run(paid, alertState: out.state).alerts, [])
    }

    func testStateSurvivesOlderBlobs() throws {
        let s = try JSONDecoder().decode(AlertState.self, from: Data(#"{"seeded":true,"fired":{"fleet.5h":[90]}}"#.utf8))
        XCTAssertTrue(s.seeded)
        XCTAssertEqual(s.fired["fleet.5h"], [90])
        XCTAssertEqual(s.blockedByAccount, [:])
        let p = try JSONDecoder().decode(AlertPrefs.self, from: Data(#"{"levels":[80]}"#.utf8))
        XCTAssertEqual(p.levels, [80])
        XCTAssertTrue(p.rotation)
    }
}
