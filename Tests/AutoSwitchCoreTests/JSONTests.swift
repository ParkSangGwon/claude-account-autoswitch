import Foundation
import XCTest
import AutoSwitchCore

final class JSONTests: XCTestCase {
    private func parse(_ s: String) throws -> JSON { try JSON.parse(Data(s.utf8)) }

    func testBoolAndNumberAreDistinct() throws {
        XCTAssertEqual(try parse("true"), .bool(true))
        XCTAssertEqual(try parse("false"), .bool(false))
        XCTAssertEqual(try parse("1"), .number(1))
        XCTAssertEqual(try parse("0"), .number(0))
        XCTAssertEqual(try parse("[true, 1, 0, false]"), .array([.bool(true), .number(1), .number(0), .bool(false)]))
        XCTAssertNil(JSON.number(1).bool)
        XCTAssertNil(JSON.bool(true).double)
        XCTAssertEqual(JSON.bool(true).any as? Bool, true)
    }

    func testScalarAccessors() throws {
        let j = try parse(#"{"n": 3.5, "i": 7, "s": "x", "a": [1, "y"], "big": 1e17, "nested": {"k": null}}"#)
        XCTAssertEqual(j["n"].double, 3.5)
        XCTAssertNil(j["n"].string)
        XCTAssertEqual(j["i"].int, 7)
        XCTAssertNil(j["big"].int)
        XCTAssertEqual(j["s"].string, "x")
        XCTAssertEqual(j["a"][1].string, "y")
        XCTAssertTrue(j["a"][5].isNull)
        XCTAssertTrue(j["missing"].isNull)
        XCTAssertTrue(j["nested"]["k"].isNull)
        XCTAssertEqual(j["a"].stringArray, ["y"])
        XCTAssertEqual(j["s"].stringArray, [])
        XCTAssertTrue(j["s"]["deeper"].isNull)
    }

    func testDateFromEpochMilliseconds() {
        XCTAssertEqual(JSON.number(1774384968427).date, Date(timeIntervalSince1970: 1774384968.427))
        // Seconds when below the 1e11 cut-over.
        XCTAssertEqual(JSON.number(1774384968).date, Date(timeIntervalSince1970: 1774384968))
        XCTAssertNil(JSON.number(0).date)
        XCTAssertNil(JSON.number(-5).date)
        XCTAssertNil(JSON.null.date)
        XCTAssertNil(JSON.bool(true).date)
    }

    func testDateFromISO8601() throws {
        let fractional = try XCTUnwrap(JSON.string("2026-09-06T17:02:37.537Z").date)
        XCTAssertEqual(fractional.timeIntervalSince1970, 1788714157.537, accuracy: 0.001)
        let whole = try XCTUnwrap(JSON.string("2026-09-06T17:02:37Z").date)
        XCTAssertEqual(whole.timeIntervalSince1970, 1788714157, accuracy: 0.001)
        let offset = try XCTUnwrap(JSON.string("2026-09-06T19:02:37+02:00").date)
        XCTAssertEqual(offset.timeIntervalSince1970, 1788714157, accuracy: 0.001)
        XCTAssertNil(JSON.string("not-a-date").date)
        XCTAssertNil(JSON.string("").date)
    }

    func testPrettyFormat() {
        let value: JSON = .object([
            "b": .object([:]),
            "a": .array([]),
            "c": .number(10912),
            "d": .number(1774384968427),
            "e": .number(0.5),
            "f": .string("q\"b\\n\nc\u{01}\ttab\u{08}\u{0C}\r"),
            "g": .bool(true),
            "h": .null,
            "i": .array([.number(1), .string("x"), .object(["k": .number(-2.25)])]),
        ])
        let expected = """
        {
          "a": [],
          "b": {},
          "c": 10912,
          "d": 1774384968427,
          "e": 0.5,
          "f": "q\\"b\\\\n\\nc\\u0001\\ttab\\b\\f\\r",
          "g": true,
          "h": null,
          "i": [
            1,
            "x",
            {
              "k": -2.25
            }
          ]
        }

        """
        XCTAssertEqual(value.pretty(), expected)
        XCTAssertTrue(value.pretty().hasSuffix("}\n"))
        XCTAssertFalse(value.pretty().contains("\" :"), "no space before the colon")
    }

    func testPrettyScalarsAndNonFinite() {
        XCTAssertEqual(JSON.number(0.98).pretty(), "0.98\n")
        XCTAssertEqual(JSON.number(-0).pretty(), "0\n")
        XCTAssertEqual(JSON.number(.nan).pretty(), "null\n")
        XCTAssertEqual(JSON.number(.infinity).pretty(), "null\n")
        XCTAssertEqual(JSON.string("héllo ☃").pretty(), "\"héllo ☃\"\n")
        XCTAssertEqual(JSON.array([]).pretty(), "[]\n")
        XCTAssertEqual(JSON.object([:]).pretty(), "{}\n")
    }

    func testPrettyRoundTrips() throws {
        let original: JSON = .object([
            "accounts": .array([.object(["name": .string("a\u{01}b\n\"\\"), "priority": .number(0), "disabled": .bool(false)])]),
            "switchThreshold": .number(0.98),
            "port": .number(10912),
            "reset": .number(1774384968427),
            "nothing": .null,
            "empty": .object(["list": .array([]), "map": .object([:])]),
            "unicode": .string("日本語 \u{7f} \u{2028}"),
        ])
        let again = try JSON.parse(Data(original.pretty().utf8))
        XCTAssertEqual(again, original)
        XCTAssertEqual(again.pretty(), original.pretty())
    }

    func testAnyBridging() throws {
        let j: JSON = .object(["a": .array([.number(1), .bool(true), .null, .string("s")])])
        let data = try JSONSerialization.data(withJSONObject: j.any, options: [.sortedKeys])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"a":[1,true,null,"s"]}"#)
        XCTAssertEqual(JSON(any: j.any), j)
    }
}
