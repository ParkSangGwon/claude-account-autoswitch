import XCTest
@testable import AutoSwitchEngine
@testable import AutoSwitchCore

/// A loopback stand-in for platform.claude.com and api.anthropic.com.
final class FakeAnthropic: @unchecked Sendable {
    let server: HTTPServer
    let lock = NSLock()
    var tokenRequests: [JSON] = []
    var refreshStatus = 200
    var usageStatus = 200
    /// The bearer token of every `/v1/messages` call, in order: what keep-alive sent and on whose behalf.
    var pings: [String] = []
    var pingStatus = 200
    /// How far ahead of the reply the five-hour window is said to roll over.
    var pingResetsIn: TimeInterval = 5 * 3600

    init() {
        let box = Box()
        server = HTTPServer(port: 0) { req in box.owner!.handle(req) }
        box.owner = self
    }
    final class Box: @unchecked Sendable { var owner: FakeAnthropic? }

    func handle(_ req: HTTPRequest) -> HTTPResponse {
        switch req.path {
        case "/v1/oauth/token":
            let body = (try? JSON.parse(req.body)) ?? .null
            lock.lock(); tokenRequests.append(body); let status = refreshStatus; lock.unlock()
            if body["grant_type"].string == "refresh_token", status != 200 { return HTTPResponse(status: status, json: .object(["error": .string("invalid_grant")])) }
            let suffix = body["grant_type"].string == "refresh_token" ? "refreshed" : "exchanged"
            return HTTPResponse(status: 200, json: .object(["access_token": .string("at-\(suffix)"), "refresh_token": .string("rt-\(suffix)"), "expires_in": .number(3600)]))
        case "/api/oauth/profile":
            return HTTPResponse(status: 200, json: .object(["account": .object(["uuid": .string("acct-1"), "email": .string("alice@example.com")]),
                                                           "organization": .object(["uuid": .string("org-1"), "name": .string("Example Org"), "rate_limit_tier": .string("default_claude_max_20x")])]))
        case "/api/oauth/usage":
            lock.lock(); let status = usageStatus; lock.unlock()
            if status != 200 { return HTTPResponse(status: status, json: .object(["error": .string("unauthorized")])) }
            return HTTPResponse(status: 200, json: .object(["five_hour": .object(["utilization": .number(42), "resets_at": .string("2030-01-01T00:00:00Z")]),
                                                           "seven_day": .object(["utilization": .number(61), "resets_at": .string("2030-01-03T00:00:00Z")]),
                                                           "limits": .array([.object(["group": .string("weekly"), "percent": .number(88), "resets_at": .string("2030-01-03T00:00:00Z"), "scope": .object(["model": .object(["display_name": .string("Fable")])])])])]))
        case "/v1/messages":
            lock.lock()
            pings.append(req.header("authorization") ?? "")
            let status = pingStatus, resetsIn = pingResetsIn
            lock.unlock()
            if status != 200 { return HTTPResponse(status: status, json: .object(["error": .string("refused")])) }
            let reset = String(Int(Date().addingTimeInterval(resetsIn).timeIntervalSince1970))
            return HTTPResponse(status: 200, headers: [("content-type", "application/json"),
                                                       ("anthropic-ratelimit-unified-5h-utilization", "0.01"),
                                                       ("anthropic-ratelimit-unified-5h-reset", reset)],
                                body: .data(Data(#"{"type":"message"}"#.utf8)))
        default:
            return HTTPResponse(status: 404, json: .null)
        }
    }

    func start() async throws {
        try await server.start()
        let base = "http://127.0.0.1:\(server.boundPort)"
        OAuth.endpoints = OAuth.Endpoints(token: URL(string: base + "/v1/oauth/token")!, profile: URL(string: base + "/api/oauth/profile")!,
                                          usage: URL(string: base + "/api/oauth/usage")!, messages: URL(string: base + "/v1/messages")!)
    }

    func stop() async { await server.stop(); OAuth.endpoints = OAuth.Endpoints() }
}

final class EngineAccountsTests: XCTestCase {
    private func freshEngine(accounts: [AccountRecord] = [], probe: Int = 0) throws -> Engine {
        Engine(store: try temporaryStore(testConfiguration(accounts: accounts, probe: probe)), version: "t")
    }

    func testPasteCodeLoginAddsTheAccountWithItsProfile() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let engine = try freshEngine()
        try await engine.load()
        let events = EventLog()
        let task = Task { try await engine.addAccount(.pasteCode, label: nil) { events.add($0) } }
        // The sheet gets the URL, the user pastes code#state from the page.
        var url: URL?
        for _ in 0..<50 { if let u = events.url { url = u; break }; try await Task.sleep(for: .milliseconds(20)) }
        let state = try XCTUnwrap(URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        await engine.submitLoginCode("thecode#\(state)")
        let added = try await task.value
        XCTAssertEqual(added, 1)
        let s = await engine.state()
        XCTAssertEqual(s.accounts.map(\.label), ["alice@example.com"])
        XCTAssertEqual(s.accounts.first?.organization?.name, "Example Org")
        XCTAssertEqual(s.accounts.first?.plan, .max(multiplier: 20))
        let onDisk = try engine.store.load().accounts[0]
        XCTAssertEqual(onDisk.credential, .oauth(OAuthTokens(access: "at-exchanged", refresh: "rt-exchanged", expiresAt: onDisk.credential.oauthExpiry)))
        XCTAssertEqual(onDisk.claudeAccountID, "acct-1")
        let sent = fake.tokenRequests.first
        XCTAssertEqual(sent?["grant_type"].string, "authorization_code")
        XCTAssertEqual(sent?["code"].string, "thecode")
        XCTAssertEqual(sent?["redirect_uri"].string, OAuth.manualRedirectURI)
        XCTAssertEqual(sent?["client_id"].string, OAuth.clientID)
    }

    func testBrowserLoginCallbackChecksTheState() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let engine = try freshEngine()
        try await engine.load()
        let events = EventLog()
        let task = Task { try await engine.addAccount(.browser, label: nil) { events.add($0) } }
        var url: URL?
        for _ in 0..<50 { if let u = events.url { url = u; break }; try await Task.sleep(for: .milliseconds(20)) }
        let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: try XCTUnwrap(url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let redirect = try XCTUnwrap(q["redirect_uri"])
        // A wrong state is refused and the login keeps waiting; the right one completes it.
        let (_, bad) = try await URLSession.shared.data(from: URL(string: redirect + "?code=c&state=nope")!)
        XCTAssertEqual((bad as? HTTPURLResponse)?.statusCode, 400)
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        let (_, good) = try await session.data(from: URL(string: redirect + "?code=c&state=\(q["state"]!)")!)
        XCTAssertEqual((good as? HTTPURLResponse)?.statusCode, 302)
        let added = try await task.value
        XCTAssertEqual(added, 1)
        XCTAssertEqual(fake.tokenRequests.first?["redirect_uri"].string, redirect)
    }

    func testImportedAccountIsUpdatedNotDuplicated() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let existing = AccountRecord(id: AccountID(rawValue: "keep-me"), label: "Work", rank: 3, organization: Organization(name: nil, id: "org-1"), claudeAccountID: "acct-1",
                                     credential: .oauth(OAuthTokens(access: "old", refresh: "old-r", expiresAt: nil)))
        let engine = try freshEngine(accounts: [existing])
        try await engine.load()
        let file = FileManager.default.temporaryDirectory.appending(path: "creds-\(UUID().uuidString).json")
        try Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-new","refreshToken":"sk-ant-ort01-new"}}"#.utf8).write(to: file)
        _ = try await engine.addAccount(.credentialsFile(file.path), label: nil) { _ in }
        let rows = try engine.store.load().accounts
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].label, "Work", "the user's label and rank survive")
        XCTAssertEqual(rows[0].rank, 3)
        XCTAssertEqual(rows[0].id.rawValue, "keep-me")
        XCTAssertEqual(rows[0].credential.oauthAccess, "sk-ant-oat01-new")
    }

    func testAPIKeyIsAddedAsIs() async throws {
        let engine = try freshEngine()
        try await engine.load()
        _ = try await engine.addAccount(.apiKey(" sk-ant-api03-abc "), label: nil) { _ in }
        let rows = try engine.store.load().accounts
        XCTAssertEqual(rows.map(\.label), ["api-key"])
        XCTAssertEqual(rows[0].credential, .apiKey("sk-ant-api03-abc"))
        do { _ = try await engine.addAccount(.apiKey("nope"), label: nil) { _ in }; XCTFail() } catch let e as EngineError { XCTAssertEqual(e, .oauth("That does not look like an Anthropic API key")) }
        try await engine.removeAccount(rows[0].id)
        XCTAssertEqual(try engine.store.load().accounts, [])
    }

    func testRefreshIsSingleFlightAndADeadTokenMarksTheAccount() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let engine = try freshEngine(accounts: [oauthAccount("a", expiresIn: -1)])
        try await engine.load()
        let id = AccountID(rawValue: "id-a")
        async let one = engine.ensureFreshToken(id)
        async let two = engine.ensureFreshToken(id)
        let results = await (one, two)
        XCTAssertEqual(results.0, true); XCTAssertEqual(results.1, true)
        XCTAssertEqual(fake.tokenRequests.count, 1, "two callers, one refresh")
        XCTAssertEqual(try engine.store.load().accounts[0].credential.oauthAccess, "at-refreshed")
        // The next refresh is rejected outright: the account is marked and the token never sent again.
        fake.refreshStatus = 401
        let first = await engine.ensureFreshToken(id, force: true)
        let second = await engine.ensureFreshToken(id, force: true)
        XCTAssertFalse(first); XCTAssertFalse(second)
        XCTAssertEqual(fake.tokenRequests.count, 2)
        let s = await engine.state()
        XCTAssertEqual(s.accounts[0].blocker, .needsLogin)
        XCTAssertEqual(s.accounts[0].health, .needsLogin)
    }

    func testProbeFillsTheWindows() async throws {
        let fake = FakeAnthropic(); try await fake.start(); defer { Task { await fake.stop() } }
        let engine = try freshEngine(accounts: [oauthAccount("a", plan: .unknown)], probe: 300)
        try await engine.load()
        await engine.probeNow()
        let s = await engine.state()
        let w = s.accounts[0].windows
        XCTAssertEqual(try XCTUnwrap(w[.session]?.used), 0.42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(w[.weekly]?.used), 0.61, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(w[.weeklyFable]?.used), 0.88, accuracy: 1e-9)
        XCTAssertNil(s.accounts[0].probe?.error)
        XCTAssertEqual(s.accounts[0].plan, .max(multiplier: 20), "the probe fetched the profile for an account without a plan")
        XCTAssertEqual(try engine.store.load().accounts[0].plan, .max(multiplier: 20))
        XCTAssertEqual(try XCTUnwrap(Fleet.total(s, .session)?.used), 0.42, accuracy: 1e-9)
        XCTAssertNotNil(s.probe.lastFinishedAt)
    }
}

extension Credential {
    var oauthAccess: String? { if case .oauth(let t) = self { return t.access } else { return nil } }
    var oauthExpiry: Date? { if case .oauth(let t) = self { return t.expiresAt } else { return nil } }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AccountEvent] = []
    func add(_ e: AccountEvent) { lock.lock(); events.append(e); lock.unlock() }
    var url: URL? { lock.lock(); defer { lock.unlock() }; for case .openURL(let u) in events { return u }; return nil }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
