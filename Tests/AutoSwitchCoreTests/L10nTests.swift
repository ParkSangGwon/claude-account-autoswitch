import XCTest
@testable import AutoSwitchCore

final class L10nTests: XCTestCase {
    override func tearDown() { L10n.activate("en") }

    func testSystemDefaultPicksAShippedLanguage() {
        XCTAssertEqual(L10n.systemDefault(preferences: ["ko-KR", "en-US"]), "ko")
        XCTAssertEqual(L10n.systemDefault(preferences: ["zh-Hans-CN"]), "zh-Hans")
        XCTAssertEqual(L10n.systemDefault(preferences: ["pt-BR", "de-DE"]), "de")
        XCTAssertEqual(L10n.systemDefault(preferences: ["xx"]), "en")
    }

    func testEnglishIsTheKey() {
        L10n.activate("en")
        XCTAssertEqual(L("Accounts"), "Accounts")
        XCTAssertEqual(L("Resets in %@", "3h"), "Resets in 3h")
        XCTAssertFalse(L10n.translationMissing)
    }

    func testUnknownCodeLandsOnAShippedLanguage() {
        let code = L10n.activate("tlh")
        XCTAssertTrue(L10n.supported.contains { $0.code == code })
        XCTAssertEqual(L10n.language, code)
    }

    /// `swift test` always builds the resource bundle, so not finding it is a broken lookup, never a skip.
    func testKoreanTableLoadsFromTheResourceBundle() throws {
        _ = try XCTUnwrap(L10n.resourceBundle(), "resource bundle not found beside the test bundle")
        XCTAssertEqual(L10n.activate("ko"), "ko")
        XCTAssertEqual(L("Accounts"), "계정")
        XCTAssertEqual(L("no-such-key"), "no-such-key")
        XCTAssertFalse(L10n.translationMissing)
    }

    /// Every shipped translation keeps the source string's placeholders in the same order, so `String(format:)`
    /// never reads an Int as an object or past its arguments. Positional forms may reorder.
    func testShippedTablesKeepPlaceholders() throws {
        _ = try XCTUnwrap(L10n.resourceBundle())
        let spec = try NSRegularExpression(pattern: "%(?:\\d+\\$)?[@d%]")
        let tokens = try NSRegularExpression(pattern: "%%|%(?:\\d+\\$)?[@d]|%")
        func placeholders(_ s: String) -> (kinds: [String], positional: Bool) {
            let found = spec.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }
            let positional = found.contains { $0.contains("$") }
            return (found.map { $0.replacingOccurrences(of: "[0-9]+\\$", with: "", options: .regularExpression) }, positional)
        }
        for code in L10n.supported.map(\.code) where code != "en" {
            let table = L10n.loadTable(code)
            XCTAssertFalse(table.isEmpty, "\(code) has no table")
            for (key, value) in table {
                let k = placeholders(key), v = placeholders(value)
                if v.positional {
                    XCTAssertEqual(k.kinds.sorted(), v.kinds.sorted(), "\(code): placeholders differ for \(key)")
                } else {
                    XCTAssertEqual(k.kinds, v.kinds, "\(code): placeholders differ or are reordered without %n$ in \(key)")
                }
                XCTAssertFalse(value.isEmpty, "\(code): empty translation for \(key)")
                // A bare % is fine in a plain label, fatal in a format string: `%s` would read a C string off the stack.
                if !k.kinds.isEmpty {
                    let bare = tokens.matches(in: value, range: NSRange(value.startIndex..., in: value)).contains { $0.range.length == 1 }
                    XCTAssertFalse(bare, "\(code): stray % in \(value)")
                }
            }
        }
    }

    func testAllLanguagesShipTheSameKeys() throws {
        _ = try XCTUnwrap(L10n.resourceBundle())
        let tables = L10n.supported.map(\.code).filter { $0 != "en" }.map { ($0, Set(L10n.loadTable($0).keys)) }
        guard let first = tables.first else { return }
        for (code, keys) in tables.dropFirst() where keys != first.1 {
            XCTFail("\(code) and \(first.0) ship different keys: \(keys.symmetricDifference(first.1).sorted().prefix(5))")
        }
    }

    /// Every `L("…")` literal in the sources and every catalog label and help
    /// has a row in the Korean table — a new string that forgot its translations fails here, not on a user's screen.
    func testEverySourceStringHasATranslation() throws {
        _ = try XCTUnwrap(L10n.resourceBundle())
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 10, "source tree not found at \(sources.path)")
        let literal = try NSRegularExpression(pattern: "\\bL\\(\"((?:[^\"\\\\]|\\\\.)*)\"")
        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let raw = String(text[Range(m.range(at: 1), in: text)!])
                keys.insert(raw.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\").replacingOccurrences(of: "\\n", with: "\n"))
            }
        }
        for f in SettingsCatalog.fields + SettingsCatalog.accountFields { keys.insert(f.label); keys.insert(f.help) }
        let table = L10n.loadTable("ko")
        let missing = keys.filter { table[$0] == nil }.sorted()
        XCTAssertEqual(missing, [], "strings without a Korean row (add them to every Localizable.strings)")
    }
}

extension L10nTests {
    /// Weekday and month names follow the app language; the hour convention stays the Mac's.
    func testDatesFollowTheAppLanguage() throws {
        _ = try XCTUnwrap(L10n.resourceBundle())
        let monday = Date(timeIntervalSince1970: 1_757_894_400) // 2025-09-15 00:00 UTC, a Monday
        L10n.activate("ko")
        XCTAssertEqual(L10n.locale.language.languageCode?.identifier, "ko")
        XCTAssertEqual(L10n.locale.region, Locale.current.region)
        let ko = monday.formatted(Date.FormatStyle().weekday(.abbreviated).locale(L10n.locale))
        L10n.activate("en")
        let en = monday.formatted(Date.FormatStyle().weekday(.abbreviated).locale(L10n.locale))
        XCTAssertNotEqual(ko, en)
        XCTAssertTrue(en.hasPrefix("Mon") || en.hasPrefix("Sun"), "en weekday, whichever side of midnight the Mac's zone is on: \(en)")
        L10n.activate("zh-Hans")
        XCTAssertEqual(L10n.locale.language.script?.identifier, "Hans")
    }
}
