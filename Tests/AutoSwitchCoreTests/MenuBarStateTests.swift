import XCTest
@testable import AutoSwitchCore

final class MenuBarStateTests: XCTestCase {
    let now = Fixture.now

    override func setUp() { L10n.activate("en") }

    private func compute(_ state: EngineState?, reachable: Bool = true, lastSuccess: TimeInterval? = 0, rotatedTo: String? = nil, rotatedAgo: TimeInterval = 0, pin: Bool = false, remaining: Bool = false) -> IconModel {
        MenuBarState.compute(IconInputs(state: state, reachable: reachable, lastSuccessAt: lastSuccess.map { now.addingTimeInterval(-$0) }, now: now, pollInterval: 30,
                                        rotatedAt: rotatedTo == nil ? nil : now.addingTimeInterval(-rotatedAgo), rotatedTo: rotatedTo, pinCurrent: pin, showRemaining: remaining))
    }

    func testDownStartingAndEmpty() {
        XCTAssertEqual(compute(nil, reachable: false, lastSuccess: nil).state, .proxyDown)
        XCTAssertEqual(compute(nil, reachable: false, lastSuccess: nil).label, "—")
        XCTAssertEqual(compute(nil).state, .starting)
        let empty = compute(Fixture.state([]))
        XCTAssertEqual(empty.state, .noAccounts)
        XCTAssertEqual(empty.label, "0%")
    }

    func testFleetLabelLeadsWithTheCountdown() {
        let s = Fixture.state([Fixture.account("ted", session: 0.30, sessionReset: 2 * 3600, weekly: 0.40), Fixture.account("bob", session: 0.30, sessionReset: 3 * 3600, weekly: 0.40)], current: "ted")
        let m = compute(s)
        XCTAssertEqual(m.state, .normal)
        XCTAssertEqual(m.label, "2h 30%")
        XCTAssertEqual(m.weeklyLabel, "3d 40%")
        XCTAssertNil(m.tag)
        XCTAssertEqual(try XCTUnwrap(m.fiveHour), 0.30, accuracy: 1e-9)
        XCTAssertTrue(m.tooltip.hasPrefix("Claude AutoSwitch · current ted · 5h 30% · 7d 40% · 5h resets in 2h · 2/2 accounts available"))
    }

    func testPinnedShowsTheCurrentAccountWithItsTag() {
        let s = Fixture.state([Fixture.account("ted", session: 0.58, sessionReset: 2 * 3600, weekly: 0.4), Fixture.account("bob", session: 0.1, weekly: 0.1)], current: "ted")
        let m = compute(s, pin: true)
        XCTAssertEqual(m.label, "2h 58%")
        XCTAssertEqual(m.tag, "ted")
        XCTAssertEqual(compute(s, pin: true, remaining: true).label, "2h 42%")
        XCTAssertEqual(compute(s, remaining: true).label, "1h 66%", "the fleet counts down to the earliest reset")
    }

    func testCriticalAtTheThresholdAndWhenNothingCanServe() {
        let hot = Fixture.state([Fixture.account("a", session: 0.94, sessionReset: nil, weekly: 0.1)], current: "a")
        let m = compute(hot)
        XCTAssertEqual(m.state, .critical)
        XCTAssertEqual(m.label, "94%!")
        XCTAssertTrue(m.tooltip.hasPrefix("Critical: at the switch threshold"))
        let out = Fixture.state([Fixture.account("a", session: 0.1, weekly: 0.1, blocker: .coolingDown(until: now))], current: "a")
        XCTAssertEqual(compute(out).state, .critical)
        XCTAssertTrue(compute(out).tooltip.hasPrefix("Critical: every account is out of rotation"))
        let movedOn = Fixture.state([Fixture.account("a", session: 0.1, weekly: 0.1, blocker: .drained, health: .drained), Fixture.account("b", session: 0.1, weekly: 0.1)], current: "a", next: "b")
        XCTAssertEqual(compute(movedOn).state, .normal, "traffic already moved: ordinary rotation")
    }

    func testWarningFromPaceRotatingAndStale() {
        // 60 % used with only 20 % of the window gone: usage runs far ahead of the clock.
        let racing = Fixture.state([Fixture.account("a", session: 0.60, sessionReset: 4 * 3600, weekly: 0.1)], current: "a")
        XCTAssertEqual(compute(racing).state, .warning)
        XCTAssertTrue(compute(racing).tooltip.hasPrefix("Warning"))
        let s = Fixture.state([Fixture.account("a", session: 0.3, weekly: 0.1)], current: "a")
        let rotating = compute(s, rotatedTo: "ParkSangGwon", rotatedAgo: 2)
        XCTAssertEqual(rotating.state, .rotating(to: "ParkSangGwon"))
        XCTAssertEqual(rotating.label, "→ par")
        XCTAssertEqual(compute(s, rotatedTo: "ParkSangGwon", rotatedAgo: 10).state, .normal)
        let stale = compute(s, lastSuccess: 200)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.label, "1h 30%", "the bars keep showing the last numbers")
    }

    func testWindowLabelWithoutAReset() {
        XCTAssertEqual(MenuBarState.windowLabel(used: 0.42, resetsAt: nil, now: now, remaining: false), "42%")
        XCTAssertEqual(MenuBarState.windowLabel(used: 0.42, resetsAt: now.addingTimeInterval(72 * 60), now: now, remaining: false), "1h12m 42%")
    }
}
