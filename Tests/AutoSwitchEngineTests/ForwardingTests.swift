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
}

