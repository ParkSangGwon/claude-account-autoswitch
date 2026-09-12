import XCTest
@testable import AutoSwitchEngine
@testable import AutoSwitchCore

final class OAuthTests: XCTestCase {
    func testPKCEShape() {
        let p = OAuth.PKCE()
        XCTAssertEqual(p.verifier.count, 43, "32 random bytes, base64url without padding")
        XCTAssertEqual(p.challenge.count, 43)
        XCTAssertEqual(p.state.count, 43)
        XCTAssertFalse(p.verifier.contains("=") || p.verifier.contains("+") || p.verifier.contains("/"))
        XCTAssertNotEqual(OAuth.PKCE().state, p.state)
    }

    func testAuthorizeURLCarriesEveryParameterClaudeCodeSends() throws {
        let p = OAuth.PKCE()
        let url = OAuth.authorizeURL(redirectURI: "http://localhost:5555/callback", pkce: p)
        let c = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.host, "claude.ai"); XCTAssertEqual(c.path, "/oauth/authorize")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["code"], "true")
        XCTAssertEqual(q["client_id"], OAuth.clientID)
        XCTAssertEqual(q["response_type"], "code")
        XCTAssertEqual(q["redirect_uri"], "http://localhost:5555/callback")
        XCTAssertEqual(q["scope"], OAuth.scopes)
        XCTAssertEqual(q["code_challenge"], p.challenge)
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["state"], p.state)
    }

    func testPastedCodeForms() throws {
        let r1 = try OAuth.parseAuthCode("abc#st8", expectedState: "st8")
        XCTAssertEqual(r1.code, "abc"); XCTAssertEqual(r1.state, "st8")
        let r2 = try OAuth.parseAuthCode("https://console.anthropic.com/oauth/code/callback?code=xyz&state=st8", expectedState: "st8")
        XCTAssertEqual(r2.code, "xyz")
        let r3 = try OAuth.parseAuthCode("  bare  ", expectedState: "st8")
        XCTAssertEqual(r3.code, "bare"); XCTAssertEqual(r3.state, "st8")
        XCTAssertThrowsError(try OAuth.parseAuthCode("abc#wrong", expectedState: "st8"))
        XCTAssertThrowsError(try OAuth.parseAuthCode("", expectedState: "st8"))
    }

    func testTokenPairNormalisesExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let a = try OAuth.tokenPair(from: .object(["access_token": .string("A"), "refresh_token": .string("R"), "expires_in": .number(3600)]), previousRefresh: nil, now: now)
        XCTAssertEqual(a, OAuth.TokenPair(accessToken: "A", refreshToken: "R", expiresAt: now.addingTimeInterval(3600)))
        let b = try OAuth.tokenPair(from: .object(["access_token": .string("A"), "expires_at": .number(1_000_500)]), previousRefresh: "OLD", now: now)
        XCTAssertEqual(b.refreshToken, "OLD", "a reply without a refresh token keeps the old one")
        XCTAssertEqual(b.expiresAt, Date(timeIntervalSince1970: 1_000_500))
        let c = try OAuth.tokenPair(from: .object(["access_token": .string("A"), "expires_at": .number(1_000_500_000_000)]), previousRefresh: nil, now: now)
        XCTAssertEqual(c.expiresAt, Date(timeIntervalSince1970: 1_000_500_000), "milliseconds are recognised")
        let d = try OAuth.tokenPair(from: .object(["access_token": .string("A")]), previousRefresh: nil, now: now)
        XCTAssertEqual(d.expiresAt, now.addingTimeInterval(3600), "no expiry means an hour")
        XCTAssertThrowsError(try OAuth.tokenPair(from: .object(["access_token": .string("")]), previousRefresh: nil))
        XCTAssertTrue(OAuth.isExpiringSoon(now.addingTimeInterval(200), now: now))
        XCTAssertFalse(OAuth.isExpiringSoon(now.addingTimeInterval(400), now: now))
        XCTAssertFalse(OAuth.isExpiringSoon(nil, now: now))
    }

    func testUsageParsing() {
        let payload: JSON = .object([
            "five_hour": .object(["utilization": .number(44), "resets_at": .string("2026-09-02T08:50:00Z")]),
            "seven_day": .object(["utilization": .number(18), "resets_at": .string("2026-09-05T00:00:00Z")]),
            "seven_day_sonnet": .null,
            "limits": .array([
                .object(["kind": .string("session"), "group": .string("session"), "percent": .number(44)]),
                .object(["kind": .string("weekly_all"), "group": .string("weekly"), "percent": .number(18)]),
                .object(["kind": .string("weekly_scoped"), "group": .string("weekly"), "percent": .number(95), "resets_at": .string("2026-09-05T00:00:00Z"), "scope": .object(["model": .object(["display_name": .string("Fable")])])]),
            ]),
        ])
        let u = OAuth.parseUsage(payload)
        XCTAssertEqual(u.fiveHour.utilization, 0.44)
        XCTAssertEqual(u.fiveHour.resetAt, ISO8601DateFormatter().date(from: "2026-09-02T08:50:00Z"))
        XCTAssertEqual(u.sevenDay.utilization, 0.18)
        XCTAssertEqual(u.scopedWeekly["fable"]?.utilization, 0.95)
        XCTAssertNil(u.scopedWeekly["sonnet"])
    }

    func testKeychainPayloadShapes() {
        let nested = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","refreshToken":"sk-ant-ort01-y","expiresAt":1788944512424,"rateLimitTier":"default_claude_max_20x"}}"#.utf8)
        let a = Importers.parse(nested)
        XCTAssertEqual(a?.accessToken, "sk-ant-oat01-x"); XCTAssertEqual(a?.refreshToken, "sk-ant-ort01-y"); XCTAssertEqual(a?.rateLimitTier, "default_claude_max_20x")
        XCTAssertNotNil(a?.expiresAt)
        let flat = Data(#"{"accessToken":"t"}"#.utf8)
        XCTAssertEqual(Importers.parse(flat)?.accessToken, "t")
        XCTAssertNil(Importers.parse(Data(#"{"claudeAiOauth":{}}"#.utf8)))
    }
}
