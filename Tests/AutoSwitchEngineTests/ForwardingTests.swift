import XCTest
@testable import AutoSwitchEngine
@testable import AutoSwitchCore

/// A scripted stand-in for api.anthropic.com: records what the proxy sent and answers from a queue.
final class FakeUpstream: @unchecked Sendable {
    struct Seen: Sendable { var path: String; var headers: [String: String]; var body: Data }
    struct Reply: Sendable { var status: Int; var headers: [(String, String)]; var body: Data }

    let server: HTTPServer
    private let lock = NSLock()
    private(set) var seen: [Seen] = []
    var replies: [Reply] = []
    var fallback = Reply(status: 200, headers: [("content-type", "application/json")], body: Data(#"{"id":"msg","usage":{"input_tokens":10,"output_tokens":5}}"#.utf8))

    init() {
        let box = Box()
        server = HTTPServer(port: 0) { req in box.owner!.handle(req) }
        box.owner = self
    }
    final class Box: @unchecked Sendable { var owner: FakeUpstream? }

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        lock.lock(); defer { lock.unlock() }
        var h: [String: String] = [:]
        for (k, v) in req.headers { h[k.lowercased()] = v }
        seen.append(Seen(path: req.path, headers: h, body: req.body))
        if req.path == "/v1/oauth/token" {
            return HTTPResponse(status: 200, json: .object(["access_token": .string("at-refreshed"), "refresh_token": .string("rt-refreshed"), "expires_in": .number(3600)]))
        }
        let r = replies.isEmpty ? fallback : replies.removeFirst()
        var headers = r.headers
        headers.append(("content-length", String(r.body.count)))
        return HTTPResponse(status: r.status, headers: headers, body: .data(r.body))
    }

    var base: String { "http://127.0.0.1:\(server.boundPort)" }
    func start() async throws {
        try await server.start()
        OAuth.endpoints = OAuth.Endpoints(token: URL(string: base + "/v1/oauth/token")!, profile: URL(string: base + "/api/oauth/profile")!, usage: URL(string: base + "/api/oauth/usage")!)
    }
    func stop() async { await server.stop(); OAuth.endpoints = OAuth.Endpoints() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return seen.filter { $0.path != "/v1/oauth/token" }.count }
}

final class ForwardingTests: XCTestCase {
    static let quotaHeaders: [(String, String)] = [("content-type", "application/json"), ("anthropic-ratelimit-unified-5h-utilization", "42"), ("anthropic-ratelimit-unified-7d-utilization", "61"),
                                                    ("anthropic-ratelimit-unified-5h-reset", String(Int(Date().timeIntervalSince1970) + 3600)), ("anthropic-ratelimit-unified-status", "allowed")]
    static let rejected: [(String, String)] = [("content-type", "application/json"), ("retry-after", "120"), ("anthropic-ratelimit-unified-5h-status", "rejected"), ("anthropic-ratelimit-unified-5h-utilization", "100")]

    private var upstream: FakeUpstream!
    private var engine: Engine!
    private var port = 0
    let alice = AccountID(rawValue: "id-alice")
    let bob = AccountID(rawValue: "id-bob")

    override func setUp() async throws {
        upstream = FakeUpstream()
        try await upstream.start()
        port = Int.random(in: 20000..<40000)
        let accounts = [oauthAccount("alice", claudeID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), oauthAccount("bob", rank: 1, claudeID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")]
        engine = Engine(store: try temporaryStore(testConfiguration(accounts: accounts, port: port, baseURL: upstream.base)), version: "t")
        try await engine.start()
    }

    override func tearDown() async throws {
        await engine.stop()
        await upstream.stop()
    }

    private func post(_ path: String = "/v1/messages", body: String = #"{"model":"claude-sonnet-4-6","messages":[]}"#, headers: [String: String] = [:]) async throws -> (Int, Data, [AnyHashable: Any]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = "POST"
        req.httpBody = Data(body.utf8)
        req.setValue("Bearer client-token", forHTTPHeaderField: "authorization")
        req.setValue("oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14", forHTTPHeaderField: "anthropic-beta")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as! HTTPURLResponse
        return (http.statusCode, data, http.allHeaderFields)
    }

    private func account(_ id: AccountID) async -> AccountStatus { await engine.state().account(id)! }

    func testTokenIsSwappedAndTheRestPassesThrough() async throws {
        upstream.replies = [.init(status: 200, headers: Self.quotaHeaders, body: Data(#"{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":7}}"#.utf8))]
        let body = #"{"model":"claude-sonnet-4-6","metadata":{"user_id":"{\"device_id\":\"d\",\"account_uuid\":\"cccccccc-cccc-4ccc-8ccc-cccccccccccc\"}"},"messages":[]}"#
        let (status, data, _) = try await post(body: body, headers: ["x-claude-code-session-id": "sess-1"])
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":7}}"#)
        let sent = try XCTUnwrap(upstream.seen.last)
        XCTAssertEqual(sent.path, "/v1/messages")
        XCTAssertEqual(sent.headers["authorization"], "Bearer token-alice", "the client's own token is replaced")
        XCTAssertNil(sent.headers["x-api-key"])
        XCTAssertEqual(sent.headers["anthropic-beta"], "oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14", "identity headers pass through unchanged")
        XCTAssertTrue(String(decoding: sent.body, as: UTF8.self).contains("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "metadata.user_id names the account whose token went out")
        var s = await engine.state()
        XCTAssertEqual(s.current, alice)
        XCTAssertEqual(try XCTUnwrap(s.account(alice)?.windows[.session]?.used), 0.42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.account(alice)?.windows[.weekly]?.used), 0.61, accuracy: 1e-9)
        XCTAssertEqual(s.account(alice)?.traffic.requests, 1)
        // The token count lands after the body is consumed.
        for _ in 0..<50 where s.account(alice)?.traffic.inputTokens == 0 { try await Task.sleep(for: .milliseconds(20)); s = await engine.state() }
        XCTAssertEqual(s.account(alice)?.traffic.inputTokens, 12)
        XCTAssertEqual(s.account(alice)?.traffic.outputTokens, 7)
        XCTAssertEqual(s.sessions.first?.id, "sess-1")
        XCTAssertEqual(s.sessions.first?.pins[.weeklySonnet], alice)
        XCTAssertEqual(s.account(alice)?.activeSessions, 1)
    }

    func testSSEIsRelayedByteForByteAndCounted() async throws {
        let sse = "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":40}}}\n\nevent: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"hi\"}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"usage\":{\"output_tokens\":9}}\n\n"
        upstream.replies = [.init(status: 200, headers: [("content-type", "text/event-stream")], body: Data(sse.utf8))]
        let (status, data, headers) = try await post(body: #"{"model":"claude-fable-5","stream":true}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), sse)
        XCTAssertEqual((headers["Content-Type"] as? String), "text/event-stream")
        var a = await account(alice)
        for _ in 0..<50 where a.traffic.outputTokens == 0 { try await Task.sleep(for: .milliseconds(20)); a = await account(alice) }
        XCTAssertEqual(a.traffic.inputTokens, 100)
        XCTAssertEqual(a.traffic.cacheReadTokens, 40)
        XCTAssertEqual(a.traffic.outputTokens, 9)
    }

    /// The reply that hands the rotation over must not carry the leaving account's allowance:
    /// the client draws its own limit banner from these headers, and one at 100% is a limit
    /// the client is never going to hit.
    func testAllowanceHeadersDescribeTheRotationNotTheAccountThatAnswered() async throws {
        let spent: [(String, String)] = [("content-type", "application/json"), ("anthropic-ratelimit-unified-status", "rejected"),
                                         ("anthropic-ratelimit-unified-5h-status", "rejected"), ("anthropic-ratelimit-unified-5h-utilization", "100"),
                                         ("anthropic-ratelimit-unified-5h-surpassed-threshold", "true"),
                                         ("anthropic-ratelimit-unified-7d-utilization", "97")]
        // Bob answers first so the rotation knows he has room; then alice replies at her limit.
        upstream.replies = [.init(status: 200, headers: Self.quotaHeaders, body: Data("{}".utf8))]
        try await engine.update { c in c.accounts[1].rank = -1 }
        _ = try await post()
        try await engine.update { c in c.accounts[1].rank = 1 }
        upstream.replies = [.init(status: 200, headers: spent, body: Data(#"{"id":"msg_6"}"#.utf8))]
        let (status, _, headers) = try await post()
        XCTAssertEqual(status, 200)
        func header(_ name: String) -> String? { headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String }
        XCTAssertEqual(header("anthropic-ratelimit-unified-5h-utilization"), "42", "bob's room is what the client can still spend")
        XCTAssertEqual(header("anthropic-ratelimit-unified-7d-utilization"), "61")
        XCTAssertEqual(header("anthropic-ratelimit-unified-status"), "allowed")
        XCTAssertEqual(header("anthropic-ratelimit-unified-5h-status"), "allowed")
        XCTAssertEqual(header("anthropic-ratelimit-unified-5h-surpassed-threshold"), "false")
        // The engine still learned the truth about alice from the same headers.
        let s = await engine.state()
        XCTAssertEqual(try XCTUnwrap(s.account(alice)?.windows[.session]?.used), 1, accuracy: 1e-9)
    }

    func testARefusalWithNothingLeftReachesTheClientUnchanged() async throws {
        upstream.replies = [.init(status: 429, headers: Self.rejected, body: Data()), .init(status: 429, headers: Self.rejected, body: Data())]
        let (status, _, headers) = try await post()
        XCTAssertEqual(status, 429)
        func header(_ name: String) -> String? { headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String }
        XCTAssertEqual(header("anthropic-ratelimit-unified-5h-utilization"), "100", "with nothing left to serve, the client is told the truth")
        XCTAssertEqual(header("anthropic-ratelimit-unified-5h-status"), "rejected")
    }

    func testRewriteKeepsTheShapeOfEachValue() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let allowance: [WindowKind: WindowReading] = [.session: WindowReading(used: 0.07, resetsAt: reset)]
        let out = Signals.rewrite([("anthropic-ratelimit-unified-5h-utilization", "99"), ("anthropic-ratelimit-unified-5h-reset", "1700000000"),
                                   ("anthropic-ratelimit-unified-7d-utilization", "88"), ("retry-after", "120")], as: allowance)
        let map = Dictionary(uniqueKeysWithValues: out)
        XCTAssertEqual(map["anthropic-ratelimit-unified-5h-utilization"], "7", "a percentage stays a percentage")
        XCTAssertEqual(map["anthropic-ratelimit-unified-5h-reset"], "1800000000", "an epoch stays an epoch")
        XCTAssertEqual(map["anthropic-ratelimit-unified-7d-utilization"], "88", "a window the rotation has no reading for is left alone")
        XCTAssertEqual(map["retry-after"], "120")
        let decimal = Signals.rewrite([("anthropic-ratelimit-unified-5h-utilization", "0.99")], as: allowance)
        XCTAssertEqual(decimal.first?.1, "0.070", "a fraction stays a fraction")
        XCTAssertEqual(Signals.rewrite([("anthropic-ratelimit-unified-5h-utilization", "99")], as: [:]).first?.1, "99", "nothing to say, nothing rewritten")
    }

    func testAQuotaRejectionRotatesToTheNextAccount() async throws {
        upstream.replies = [.init(status: 429, headers: Self.rejected, body: Data(#"{"type":"error"}"#.utf8)),
                            .init(status: 200, headers: Self.quotaHeaders, body: Data(#"{"id":"msg_2"}"#.utf8))]
        let (status, data, _) = try await post()
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"id":"msg_2"}"#)
        XCTAssertEqual(upstream.count, 2)
        XCTAssertEqual(upstream.seen[0].headers["authorization"], "Bearer token-alice")
        XCTAssertEqual(upstream.seen[1].headers["authorization"], "Bearer token-bob")
        let s = await engine.state()
        XCTAssertEqual(s.current, bob, "the cursor follows the account that served")
        XCTAssertEqual(s.next, bob)
        if case .coolingDown = s.account(alice)?.blocker {} else { XCTFail("alice should be cooling down: \(String(describing: s.account(alice)?.blocker))") }
        XCTAssertEqual(s.account(alice)?.health, .coolingDown)
    }

    /// The handover as the client sees it: every request answers 200, the allowance it reads never
    /// jumps to a limit, and once alice is out the rotation stops offering her the first attempt.
    func testTheHandoverIsInvisibleToTheClient() async throws {
        func header(_ headers: [AnyHashable: Any], _ name: String) -> String? {
            headers.first { ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame }?.value as? String
        }
        let nearlySpent: [(String, String)] = [("content-type", "application/json"), ("anthropic-ratelimit-unified-status", "allowed_warning"),
                                               ("anthropic-ratelimit-unified-5h-utilization", "97"), ("anthropic-ratelimit-unified-5h-surpassed-threshold", "true")]
        upstream.replies = [.init(status: 200, headers: nearlySpent, body: Data("{}".utf8))]
        let (first, _, h1) = try await post(headers: ["x-claude-code-session-id": "s"])
        XCTAssertEqual(first, 200)
        XCTAssertEqual(header(h1, "anthropic-ratelimit-unified-5h-utilization"), "0", "bob has spent nothing, so nothing is spent")
        XCTAssertEqual(header(h1, "anthropic-ratelimit-unified-5h-surpassed-threshold"), "false")

        upstream.replies = [.init(status: 429, headers: Self.rejected, body: Data()),
                            .init(status: 200, headers: Self.quotaHeaders, body: Data("{}".utf8))]
        let (second, _, h2) = try await post(headers: ["x-claude-code-session-id": "s"])
        XCTAssertEqual(second, 200, "the refusal is absorbed, not relayed")
        XCTAssertEqual(header(h2, "anthropic-ratelimit-unified-5h-utilization"), "42", "and the client reads bob's allowance, not alice's 100")
        XCTAssertEqual(header(h2, "anthropic-ratelimit-unified-status"), "allowed")

        let before = upstream.count
        upstream.replies = [.init(status: 200, headers: Self.quotaHeaders, body: Data("{}".utf8))]
        let (third, _, _) = try await post(headers: ["x-claude-code-session-id": "s"])
        XCTAssertEqual(third, 200)
        XCTAssertEqual(upstream.count - before, 1, "alice is out, so the next request does not bounce off her first")
        XCTAssertEqual(upstream.seen.last?.headers["authorization"], "Bearer token-bob")
        let s = await engine.state()
        XCTAssertEqual(s.sessions.first?.pins[.weeklySonnet], bob, "the session moved with the rotation")
    }

    func testA401RefreshesOnceAndRetriesTheSameAccount() async throws {
        upstream.replies = [.init(status: 401, headers: [("content-type", "application/json")], body: Data(#"{"type":"error"}"#.utf8)),
                            .init(status: 200, headers: Self.quotaHeaders, body: Data(#"{"id":"msg_3"}"#.utf8))]
        let (status, _, _) = try await post()
        XCTAssertEqual(status, 200)
        let calls = upstream.seen.filter { $0.path == "/v1/messages" }
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].headers["authorization"], "Bearer token-alice")
        XCTAssertEqual(calls[1].headers["authorization"], "Bearer at-refreshed", "the retry carries the refreshed token")
        XCTAssertEqual(try engine.store.load().accounts[0].credential.oauthAccess, "at-refreshed")
    }

    func testEveryAccountOutAnswers429WithRetryAfter() async throws {
        upstream.replies = [.init(status: 429, headers: Self.rejected, body: Data()), .init(status: 429, headers: Self.rejected, body: Data())]
        let (status, _, headers) = try await post()
        XCTAssertEqual(status, 429)
        // With every account refused, the last upstream 429 is relayed as is, retry-after included.
        XCTAssertEqual((headers["Retry-After"] ?? headers["retry-after"]) as? String, "120")
        XCTAssertEqual(upstream.count, 2)
        let s = await engine.state()
        XCTAssertTrue(s.accounts.allSatisfy { $0.health == .coolingDown })
        XCTAssertTrue(s.isExhausted)
    }

    /// A 429 with no `anthropic-ratelimit-*` line at all: a burst, a busy upstream, something the
    /// account's own windows know nothing about. Sidelining the account for it takes both accounts
    /// down in turn, because whatever refused this one refuses its sibling a moment later.
    static let unattributed: [(String, String)] = [("content-type", "application/json")]

    func testA429NamingNoWindowLeavesTheAccountInRotation() async throws {
        upstream.replies = [.init(status: 429, headers: Self.unattributed, body: Data(#"{"type":"error"}"#.utf8)),
                            .init(status: 200, headers: Self.quotaHeaders, body: Data(#"{"id":"msg_5"}"#.utf8))]
        let (status, _, _) = try await post()
        XCTAssertEqual(status, 200, "the sibling serves it")
        XCTAssertEqual(upstream.count, 2)
        let s = await engine.state()
        XCTAssertNil(s.account(alice)?.blocker, "nothing said alice's windows were closed")
        XCTAssertEqual(s.account(alice)?.health, .ok)
    }

    func testUnattributed429sDoNotEmptyTheRotation() async throws {
        upstream.replies = [.init(status: 429, headers: Self.unattributed, body: Data()),
                            .init(status: 429, headers: Self.unattributed, body: Data())]
        let (status, _, _) = try await post()
        XCTAssertEqual(status, 429, "the client still sees the refusal")
        let s = await engine.state()
        XCTAssertFalse(s.isExhausted, "both accounts stay in rotation — neither was told its quota was gone")
        XCTAssertNotNil(s.next, "the next request has somewhere to go")
    }

    func testRepeatedUnattributed429sDoCoolTheAccountDown() async throws {
        for _ in 0..<AccountRuntime.unattributedRefusalsBeforeCoolDown {
            upstream.replies = [.init(status: 429, headers: Self.unattributed, body: Data()),
                                .init(status: 200, headers: Self.quotaHeaders, body: Data(#"{"id":"m"}"#.utf8))]
            _ = try await post()
        }
        let s = await engine.state()
        if case .coolingDown = s.account(alice)?.blocker {} else {
            XCTFail("refusing every request in a row is alice's own problem: \(String(describing: s.account(alice)?.blocker))")
        }
        XCTAssertNil(s.account(bob)?.blocker, "bob served them all and stays clear")
    }

    func testAServerErrorHopsOnce() async throws {
        upstream.replies = [.init(status: 503, headers: [], body: Data()), .init(status: 200, headers: Self.quotaHeaders, body: Data(#"{"id":"msg_4"}"#.utf8))]
        let (status, _, _) = try await post()
        XCTAssertEqual(status, 200)
        XCTAssertEqual(upstream.seen[1].headers["authorization"], "Bearer token-bob")
    }

    func testClientCredentialPathsKeepTheClientsToken() async throws {
        upstream.replies = [.init(status: 200, headers: [("content-type", "application/json")], body: Data(#"{"account":{}}"#.utf8))]
        let (status, _, _) = try await post("/api/oauth/profile", body: "")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(upstream.seen.last?.headers["authorization"], "Bearer client-token")
    }

    func testSpreadingGivesNewSessionsTheLeastLoadedAccount() async throws {
        try await engine.update { c in
            c.rotation.spreadSessions = true
            c.accounts[1].rank = 0
        }
        _ = try await post(headers: ["x-claude-code-session-id": "s-one"])
        _ = try await post(headers: ["x-claude-code-session-id": "s-two"])
        _ = try await post(headers: ["x-claude-code-session-id": "s-one"])
        let auths = upstream.seen.map { $0.headers["authorization"] ?? "" }
        XCTAssertEqual(auths[0], "Bearer token-alice")
        XCTAssertEqual(auths[1], "Bearer token-bob", "the second session goes to the less loaded account")
        XCTAssertEqual(auths[2], "Bearer token-alice", "a session stays with its account")
    }

    func testAFullFamilyWindowSendsThatFamilyElsewhere() async throws {
        try await engine.update { c in c.accounts[0].rank = 0; c.accounts[1].rank = 0 }
        // Alice's Fable week is spent; her shared windows are fine.
        upstream.replies = [.init(status: 200, headers: [("content-type", "application/json"), ("anthropic-ratelimit-unified-7d_oi-utilization", "99"), ("anthropic-ratelimit-unified-7d_oi-reset", "2030-01-01T00:00:00Z")], body: Data("{}".utf8))]
        _ = try await post(body: #"{"model":"claude-opus-5"}"#)
        _ = try await post(body: #"{"model":"claude-fable-5-1"}"#)
        _ = try await post(body: #"{"model":"claude-opus-5"}"#)
        let auths = upstream.seen.map { $0.headers["authorization"] ?? "" }
        XCTAssertEqual(auths, ["Bearer token-alice", "Bearer token-bob", "Bearer token-bob"], "the Fable request moved to bob and the cursor followed")
        let s = await engine.state()
        XCTAssertEqual(s.familyTargets[.fable] ?? nil, bob)
        XCTAssertNil(s.account(alice)?.blocker, "a spent family window is not a blocker for other models")
    }

    // MARK: - handing traffic over

    func testAManualSwitchTakesTheRunningSessionsWithIt() async throws {
        try await engine.update { c in c.accounts[1].rank = 0 }
        _ = try await post(headers: ["x-claude-code-session-id": "s"])
        XCTAssertEqual(upstream.seen.last?.headers["authorization"], "Bearer token-alice")
        let outcome = await engine.switchTo(bob)
        XCTAssertEqual(outcome.kind, .ok)
        _ = try await post(headers: ["x-claude-code-session-id": "s"])
        XCTAssertEqual(upstream.seen.last?.headers["authorization"], "Bearer token-bob",
                       "the terminal the switch was made for moves too, rather than carrying on where it was")
        let s = await engine.state()
        XCTAssertEqual(s.sessions.first?.pins[.weeklySonnet], bob)
    }

    func testASessionFollowsWhereItWasLastServed() async throws {
        try await engine.update { c in c.accounts[1].rank = 0 }
        _ = try await post(body: #"{"model":"claude-sonnet-4-6"}"#, headers: ["x-claude-code-session-id": "s"])
        _ = await engine.switchTo(bob)
        _ = try await post(body: #"{"model":"claude-fable-5-1"}"#, headers: ["x-claude-code-session-id": "s"])
        XCTAssertEqual(upstream.seen.last?.headers["authorization"], "Bearer token-bob")
        // A model on a window this session has no pin for follows the account that served it last,
        // not whichever pin the dictionary happens to hand over first.
        _ = try await post(body: #"{"model":"claude-opus-5"}"#, headers: ["x-claude-code-session-id": "s"])
        XCTAssertEqual(upstream.seen.last?.headers["authorization"], "Bearer token-bob")
    }

    func testRetryAfterNamesWhenAnAccountActuallyComesBack() async throws {
        // Both accounts are out on the week; their five-hour windows roll over long before that.
        let week = Date().addingTimeInterval(4 * 86_400)
        let fiveHours = Date().addingTimeInterval(900)
        let spent: [(String, String)] = [("content-type", "application/json"),
                                         ("anthropic-ratelimit-unified-7d-utilization", "100"),
                                         ("anthropic-ratelimit-unified-7d-reset", String(Int(week.timeIntervalSince1970))),
                                         ("anthropic-ratelimit-unified-5h-utilization", "10"),
                                         ("anthropic-ratelimit-unified-5h-reset", String(Int(fiveHours.timeIntervalSince1970)))]
        upstream.replies = [.init(status: 200, headers: spent, body: Data("{}".utf8))]
        try await engine.update { c in c.accounts[1].rank = -1 }
        _ = try await post()
        try await engine.update { c in c.accounts[1].rank = 1 }
        upstream.replies = [.init(status: 200, headers: spent, body: Data("{}".utf8))]
        _ = try await post()
        let (status, _, headers) = try await post()
        XCTAssertEqual(status, 429)
        let retryAfter = Double((headers.first { ($0.key as? String)?.caseInsensitiveCompare("retry-after") == .orderedSame }?.value as? String) ?? "0") ?? 0
        XCTAssertGreaterThan(retryAfter, fiveHours.timeIntervalSinceNow + 60,
                             "a five-hour rollover brings nothing back to an account whose week is what is spent")
        XCTAssertLessThanOrEqual(retryAfter, week.timeIntervalSinceNow + 1)
    }

    func testAnUnreachableUpstreamIsNotReportedAsARateLimit() async throws {
        upstream.replies = [.init(status: 429, headers: Self.rejected, body: Data()),
                            .init(status: 200, headers: Self.quotaHeaders, body: Data("{}".utf8))]
        _ = try await post()
        try await engine.update { c in c.api.baseURL = "http://127.0.0.1:\(Int.random(in: 40000..<50000))" }
        let (status, data, _) = try await post()
        XCTAssertEqual(status, 502, "nobody refused this request — it never arrived")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("rate_limit_error"))
    }

    func testARolledOverWindowDoesNotWaitForTheAppToNotice() async throws {
        // Alice's five hours are spent and roll over a second from now. Nothing reads `state()` in
        // between: with the display asleep the app polls every five minutes.
        let rollover = Date().addingTimeInterval(1)
        upstream.replies = [.init(status: 200, headers: [("content-type", "application/json"),
                                                         ("anthropic-ratelimit-unified-5h-utilization", "100"),
                                                         ("anthropic-ratelimit-unified-5h-reset", String(Int(rollover.timeIntervalSince1970)))],
                                  body: Data("{}".utf8))]
        _ = try await post()
        try await Task.sleep(for: .milliseconds(1200))
        _ = try await post()
        XCTAssertEqual(upstream.seen.last?.headers["authorization"], "Bearer token-alice",
                       "alice's window rolled over; nothing but a stale reading was holding her out")
    }

    func testAProbeDoesNotUndoWhatAReplyJustLearned() async throws {
        let asked = Date()
        try await Task.sleep(for: .milliseconds(20))
        upstream.replies = [.init(status: 200, headers: [("content-type", "application/json"), ("anthropic-ratelimit-unified-5h-utilization", "99")], body: Data("{}".utf8))]
        _ = try await post()
        // The probe left before that reply came back, so its numbers are the older pair.
        let stale = OAuth.Usage(fiveHour: (utilization: 0.1, resetAt: nil), sevenDay: (utilization: 0.2, resetAt: nil), scopedWeekly: [:])
        await engine.absorb(stale, into: 0, asked: asked)
        let s = await engine.state()
        XCTAssertEqual(try XCTUnwrap(s.account(alice)?.windows[.session]?.used), 0.99, accuracy: 1e-9,
                       "the reply that arrived mid-probe is the newer reading of the two")
        XCTAssertEqual(try XCTUnwrap(s.account(alice)?.windows[.weekly]?.used), 0.2, accuracy: 1e-9,
                       "a window the reply said nothing about still takes the probe's number")
    }

    func testAccountIDRewriteLeavesOtherBodiesAlone() {
        let body = Data(#"{"metadata":{"user_id":"{\"account_uuid\":\"11111111-1111-4111-8111-111111111111\"}"}}"#.utf8)
        let out = String(decoding: Engine.rename(claudeAccountIDIn: body, to: "22222222-2222-4222-8222-222222222222"), as: UTF8.self)
        XCTAssertTrue(out.contains("22222222-2222-4222-8222-222222222222"))
        XCTAssertFalse(out.contains("11111111"))
        XCTAssertEqual(Engine.rename(claudeAccountIDIn: Data("plain".utf8), to: "22222222-2222-4222-8222-222222222222"), Data("plain".utf8))
        XCTAssertEqual(Engine.rename(claudeAccountIDIn: body, to: nil), body)
    }

    func testSignalRules() {
        var w = Windows()
        let now = Date()
        Signals.absorb([("anthropic-ratelimit-unified-status", "rejected"), ("anthropic-ratelimit-unified-5h-status", "allowed"), ("anthropic-ratelimit-unified-7d-status", "allowed")], into: &w, now: now)
        XCTAssertFalse(w.isRefused, "a rejection no window confirms is noise")
        Signals.absorb([("anthropic-ratelimit-unified-status", "rejected"), ("anthropic-ratelimit-unified-7d-status", "rejected")], into: &w, now: now)
        XCTAssertTrue(w.isRefused)
        Signals.absorb([("anthropic-ratelimit-unified-7d_oi-utilization", "88"), ("anthropic-ratelimit-unified-7d_oi-reset", "2030-01-01T00:00:00Z")], into: &w, now: now)
        XCTAssertEqual(w[.weeklyFable]?.used, 0.88)
        XCTAssertNotNil(w[.weeklyFable]?.resetsAt)
        Signals.absorb([("anthropic-ratelimit-tokens-limit", "1000"), ("anthropic-ratelimit-tokens-remaining", "250")], into: &w, now: now)
        XCTAssertEqual(w.tokens?.used, 0.75)
        XCTAssertEqual(Signals.refusal([("anthropic-ratelimit-unified-7d_oi-status", "rejected")]), .fableWindow)
        XCTAssertEqual(Signals.refusal(Self.rejected), .sharedWindow)
        XCTAssertEqual(Signals.refusal([]), .plain)
        XCTAssertEqual(Signals.retryAfter([("Retry-After", "30")]), 30)
    }

    /// `absorb` and `refusal` read the same headers; a rejection with no window line at all must
    /// not hold the account out of rotation in one and read as noise in the other.
    func testAnUnconfirmedRejectionIsNoiseToBothReadings() {
        var w = Windows()
        let headers = [("anthropic-ratelimit-unified-status", "rejected")]
        Signals.absorb(headers, into: &w)
        XCTAssertFalse(w.isRefused, "no window named, so nothing holds the account out")
        XCTAssertEqual(Signals.refusal(headers), .plain, "and the refusal reads the same way")
    }

    func testTheWaitEndsWithACleanSlate() {
        var r = AccountRuntime(record: oauthAccount("a"))
        let t0 = Date()
        for _ in 0..<AccountRuntime.unattributedRefusalsBeforeCoolDown { r.noteUnattributedRefusal(retryAfter: 5, now: t0) }
        XCTAssertEqual(r.health, .coolingDown)
        r.sweep(now: t0.addingTimeInterval(10))
        XCTAssertEqual(r.health, .ok)
        // Without the reset the tally would still be at the threshold and one refusal would sideline it again.
        r.noteUnattributedRefusal(retryAfter: 5, now: t0.addingTimeInterval(10))
        XCTAssertEqual(r.health, .ok, "the account gets its allowance back, not a hair trigger")
    }
}

