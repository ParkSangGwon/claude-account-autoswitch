import XCTest
@testable import AutoSwitchCore

final class HistoryTests: XCTestCase {
    let now = Fixture.now

    private func sample(at: Date, a: String = "ok") -> HistorySample {
        HistorySample(at: at, fleetSession: 0.4, fleetWeekly: 0.5, current: "a", accounts: ["a": .init(state: a, session: 0.4, weekly: 0.5)])
    }

    func testSampleFromState() {
        let s = Fixture.state([Fixture.account("a", session: 0.3, weekly: 0.6), Fixture.account("b", session: 0.9, blocker: .coolingDown(until: now))], current: "a")
        let h = HistorySample(state: s, at: now)
        XCTAssertEqual(h.current, "a")
        XCTAssertEqual(h.accounts["a"]?.state, "ok")
        XCTAssertEqual(h.accounts["b"]?.state, "cooling")
        XCTAssertEqual(try XCTUnwrap(h.fleetSession), (20 * 0.3 + 20 * 0.9) / 40, accuracy: 1e-9)
    }

    func testOneSampleAMinuteAndSevenDaysKept() {
        var store = HistoryStore()
        XCTAssertTrue(store.record(sample(at: now)))
        XCTAssertFalse(store.record(sample(at: now.addingTimeInterval(30))), "too soon")
        XCTAssertTrue(store.record(sample(at: now.addingTimeInterval(60))))
        XCTAssertTrue(store.record(sample(at: now.addingTimeInterval(HistoryStore.retention + 120))))
        XCTAssertEqual(store.samples.count, 1, "the old samples fell out of the window")
        XCTAssertEqual(store.accountLabels, ["a"])
    }

    func testSegmentsCompressRunsAndMarkGaps() {
        var store = HistoryStore()
        for i in 0..<5 { store.record(sample(at: now.addingTimeInterval(Double(i) * 60), a: i < 3 ? "ok" : "full")) }
        // A ten-minute gap: the app was not running.
        store.record(sample(at: now.addingTimeInterval(900), a: "ok"))
        let segs = store.segments(account: "a", since: now, until: now.addingTimeInterval(960))
        XCTAssertEqual(segs.map(\.state), ["ok", "full", "absent", "ok"])
        XCTAssertEqual(segs[2].from, now.addingTimeInterval(240))
        XCTAssertEqual(segs[2].to, now.addingTimeInterval(900))
        let series = store.series(since: now, until: now.addingTimeInterval(960)) { $0.accounts["a"]?.session }
        XCTAssertEqual(series.count, 6)
    }
}
