import XCTest
@testable import AutoSwitchCore

final class SettingsCatalogTests: XCTestCase {
    private func field(_ id: String) -> SettingField { SettingsCatalog.field(id)! }

    func testEverySectionFieldReadsAndWrites() throws {
        var c = Configuration.defaults
        try SettingsCatalog.apply(field("rotation.switchAt"), value: .number(90), to: &c)
        XCTAssertEqual(c.rotation.switchAt, 0.9)
        XCTAssertEqual(SettingsCatalog.value(field("rotation.switchAt"), in: c), .number(90))

        try SettingsCatalog.apply(field("rotation.switchAtByWindow"), value: .object(["weekly": .number(0.8), "default": .number(0.95)]), to: &c)
        XCTAssertEqual(c.rotation.switchAtByWindow, [.weekly: 0.8])
        XCTAssertEqual(c.rotation.switchAt, 0.95)
        XCTAssertEqual(SettingsCatalog.value(field("rotation.switchAtByWindow"), in: c), .object(["default": .number(0.95), "weekly": .number(0.8)]))
        try SettingsCatalog.apply(field("rotation.switchAtByWindow"), value: nil, to: &c)
        XCTAssertEqual(c.rotation.switchAtByWindow, [:])

        try SettingsCatalog.apply(field("rotation.spreadSessions"), value: .string("on"), to: &c)
        XCTAssertTrue(c.rotation.spreadSessions)
        XCTAssertEqual(SettingsCatalog.value(field("rotation.spreadSessions"), in: c), .string("on"))

        try SettingsCatalog.apply(field("rotation.waitWhenExhaustedSeconds"), value: .number(120), to: &c)
        XCTAssertEqual(c.rotation.waitWhenExhaustedSeconds, 120)
        try SettingsCatalog.apply(field("quota.refreshEverySeconds"), value: .number(0), to: &c)
        XCTAssertEqual(c.quota.refreshEverySeconds, 0)
        try SettingsCatalog.apply(field("listen.port"), value: .number(4000), to: &c)
        XCTAssertEqual(c.listen.port, 4000)
        try SettingsCatalog.apply(field("api.baseURL"), value: .string("https://example.test/"), to: &c)
        XCTAssertEqual(c.api.baseURL, "https://example.test")
    }

    func testInvalidValuesAreRefused() {
        var c = Configuration.defaults
        XCTAssertThrowsError(try SettingsCatalog.apply(field("rotation.switchAt"), value: .number(0), to: &c))
        XCTAssertThrowsError(try SettingsCatalog.apply(field("listen.port"), value: .number(70000), to: &c))
        XCTAssertThrowsError(try SettingsCatalog.apply(field("api.baseURL"), value: .string("ftp://x"), to: &c))
        XCTAssertEqual(c, Configuration.defaults, "a refused value changes nothing")
    }

    func testAccountCap() throws {
        var r = AccountRecord(label: "a", credential: .apiKey("k"))
        let cap = field("cap")
        try SettingsCatalog.applyAccount(cap, value: .object(["default": .number(0.5)]), to: &r)
        XCTAssertEqual(r.cap, .uniform(0.5))
        XCTAssertEqual(SettingsCatalog.accountValue(cap, in: r), .object(["default": .number(0.5)]))
        try SettingsCatalog.applyAccount(cap, value: .object(["session": .number(0.7), "default": .number(0.9)]), to: &r)
        XCTAssertEqual(r.cap, .perWindow([.session: 0.7, .weekly: 0.9, .weeklyFable: 0.9, .weeklySonnet: 0.9]))
        try SettingsCatalog.applyAccount(cap, value: nil, to: &r)
        XCTAssertNil(r.cap)
    }

    func testAccountPlanCanBeSetWhenTheProfileNeverAnswered() throws {
        var r = AccountRecord(label: "a", planText: "default_claude_max_20x", credential: .apiKey("k"))
        let plan = field("plan")
        XCTAssertEqual(SettingsCatalog.accountValue(plan, in: r), .string("unknown"))
        XCTAssertNil(r.plan.weight, "an unknown plan is left out of the fleet total")

        try SettingsCatalog.applyAccount(plan, value: .string("max20"), to: &r)
        XCTAssertEqual(r.plan, .max(multiplier: 20))
        XCTAssertEqual(r.plan.weight, 20)
        XCTAssertNil(r.planText, "Claude's own words no longer describe what this says")
        XCTAssertEqual(SettingsCatalog.accountValue(plan, in: r), .string("max20"))

        for (key, expected) in [("pro", Plan.pro), ("max5", .max(multiplier: 5)), ("team", .team(multiplier: 1)), ("unknown", .unknown)] {
            try SettingsCatalog.applyAccount(plan, value: .string(key), to: &r)
            XCTAssertEqual(r.plan, expected)
        }
        XCTAssertThrowsError(try SettingsCatalog.applyAccount(plan, value: .string("platinum"), to: &r))
    }

    func testCatalogCoversTheSections() {
        XCTAssertEqual(SettingsCatalog.fields(in: .rotation).map(\.id), ["rotation.switchAt", "rotation.switchAtByWindow", "rotation.spreadSessions", "rotation.waitWhenExhaustedSeconds"])
        XCTAssertEqual(SettingsCatalog.fields(in: .proxy).map(\.id), ["listen.port", "api.baseURL"])
        XCTAssertEqual(SettingsCatalog.fields(in: .quota).map(\.id), ["quota.refreshEverySeconds"])
        XCTAssertEqual(SettingsCatalog.windowKeys, ["default", "session", "weekly", "weeklyFable", "weeklySonnet"])
    }
}
