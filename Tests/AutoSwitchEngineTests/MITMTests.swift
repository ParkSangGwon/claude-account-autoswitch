import XCTest
import NIOCore
import NIOPosix
@testable import AutoSwitchEngine
@testable import AutoSwitchCore

final class ConnectAuthorityTests: XCTestCase {
    func testTheFourWaysNaiveSplittingGoesWrong() {
        XCTAssertEqual(ConnectAuthority.parse("api.anthropic.com:443"), ConnectAuthority(host: "api.anthropic.com", port: 443))
        XCTAssertEqual(ConnectAuthority.parse("api.anthropic.com"), ConnectAuthority(host: "api.anthropic.com", port: 443), "a missing port means 443")

        XCTAssertEqual(ConnectAuthority.parse("[::1]:443"), ConnectAuthority(host: "::1", port: 443), "a bracketed literal keeps neither bracket")
        XCTAssertNil(ConnectAuthority.parse(":443"), "an empty host would otherwise dial localhost")
        XCTAssertEqual(ConnectAuthority.parse("API.ANTHROPIC.COM:443")?.host, "api.anthropic.com")
        XCTAssertEqual(ConnectAuthority.parse("api.anthropic.com.:443")?.host, "api.anthropic.com", "a root dot must not escape the terminate route")
        XCTAssertNil(ConnectAuthority.parse("host:0"))
        XCTAssertNil(ConnectAuthority.parse("host:70000"))
        XCTAssertNil(ConnectAuthority.parse("host:notaport"))
        XCTAssertNil(ConnectAuthority.parse(""))
    }

    func testOnlyTheAPIHostOnItsOwnPortIsTerminated() {
        XCTAssertTrue(ConnectAuthority.parse("api.anthropic.com:443")!.isTerminated)
        XCTAssertTrue(ConnectAuthority.parse("API.anthropic.com.")!.isTerminated, "normalisation happens before the decision")
        XCTAssertFalse(ConnectAuthority.parse("api.anthropic.com:80")!.isTerminated, "presenting TLS on a plaintext port would only break it")
        XCTAssertFalse(ConnectAuthority.parse("mcp-proxy.anthropic.com:443")!.isTerminated, "an Anthropic domain is not the API host")
        XCTAssertFalse(ConnectAuthority.parse("mcp.notion.com:443")!.isTerminated)
    }
}

final class TunnelPolicyTests: XCTestCase {
    func testProductionRefusesWhatWouldComeBackToUs() {
        let policy = TunnelPolicy.production(listeningPort: 10912)
        XCTAssertFalse(policy.allows(host: "localhost"))
        XCTAssertFalse(policy.allows(host: "foo.localhost"))
        XCTAssertFalse(policy.allows(host: "127.0.0.1"))
        XCTAssertFalse(policy.allows(host: "127.9.9.9"))
        XCTAssertFalse(policy.allows(host: "0.0.0.0"))
        XCTAssertFalse(policy.allows(host: "::1"))
        XCTAssertFalse(policy.allows(host: "169.254.169.254"), "the link-local metadata address")
        XCTAssertTrue(policy.allows(host: "mcp.notion.com"), "an ordinary tunnel is the common case, not the exception")
        XCTAssertTrue(policy.allows(host: "registry.npmjs.org"))
    }

    func testPermissiveIsForTestsOnly() {
        XCTAssertTrue(TunnelPolicy.permissive(listeningPort: 1).allows(host: "127.0.0.1"))
    }
}

/// The proxy end to end: a client that dials `api.anthropic.com` through CONNECT must come out at
/// `Relay.serve` carrying the rotated account's token, exactly as the plaintext path already does.
final class MITMTests: XCTestCase {
    private var upstream: FakeUpstream!
    private var engine: Engine!
    private var port = 0
    private var caPath = ""
    private let alice = AccountID(rawValue: "id-alice")

    override func setUp() async throws {
        upstream = FakeUpstream()
        try await upstream.start()
        port = Int.random(in: 20000..<40000)
        let accounts = [oauthAccount("alice", claudeID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")]
        engine = Engine(store: try temporaryStore(testConfiguration(accounts: accounts, port: port, baseURL: upstream.base)), version: "t")
        try await engine.start()
        caPath = await engine.state().listener.caPath
    }

    override func tearDown() async throws {
        await engine.stop()
        await upstream.stop()
    }

    /// curl is the client here rather than a hand-rolled NIO one: it does CONNECT, SNI and chain
    /// verification the way the real client does, so a mistake in any of them fails the test.
    @discardableResult
    private func curl(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private var proxyArguments: [String] {
        ["--proxy", "http://127.0.0.1:\(port)", "--cacert", caPath, "--max-time", "20", "-s", "-o", "-", "-w", "\n%{http_code}"]
    }

    func testTerminatedRequestGetsTheRotatedToken() throws {
        upstream.replies = [.init(status: 200, headers: [("content-type", "application/json")],
                                  body: Data(#"{"id":"msg_1","usage":{"input_tokens":12,"output_tokens":7}}"#.utf8))]
        let body = #"{"model":"claude-sonnet-4-6","metadata":{"user_id":"{\"account_uuid\":\"cccccccc-cccc-4ccc-8ccc-cccccccccccc\"}"},"messages":[]}"#
        let result = try curl(proxyArguments + [
            "https://api.anthropic.com/v1/messages",
            "-H", "authorization: Bearer client-token",
            "-H", "anthropic-beta: oauth-2025-04-20",
            "-H", "content-type: application/json",
            "--data-binary", body,
        ])
        XCTAssertEqual(result.status, 0, "curl verified our leaf against our CA: \(result.output)")
        XCTAssertTrue(result.output.hasSuffix("200"), result.output)

        let sent = try XCTUnwrap(upstream.seen.last)
        XCTAssertEqual(sent.path, "/v1/messages")
        XCTAssertEqual(sent.headers["authorization"], "Bearer token-alice", "the client's own token is replaced inside the tunnel too")
        XCTAssertEqual(sent.headers["anthropic-beta"], "oauth-2025-04-20", "identity headers still pass through")
        XCTAssertTrue(String(decoding: sent.body, as: UTF8.self).contains("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"),
                      "metadata.user_id is rewritten to the account whose token went out")
    }

    func testTheHealthEndpointStillAnswersInTheClear() throws {
        // What `scripts/smoke.sh` does, proxy variables deliberately out of the way.
        let result = try curl(["--noproxy", "*", "--max-time", "10", "-s", "-o", "-", "-w", "\n%{http_code}",
                               "http://127.0.0.1:\(port)/_autoswitch/health"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.hasSuffix("200"), result.output)
    }

    func testTheHealthEndpointIsNotCountedAsALegacyClient() async throws {
        for _ in 0..<5 {
            _ = try curl(["--noproxy", "*", "--max-time", "10", "-s", "-o", "/dev/null", "http://127.0.0.1:\(port)/_autoswitch/health"])
        }
        let state = await engine.state()
        XCTAssertEqual(state.listener.legacyRequests, 0, "the app's own health check must not make the app accuse itself")
    }

    func testAnOriginFormRequestIsServedAndCountedAsLegacy() async throws {
        let result = try curl(["--noproxy", "*", "--max-time", "20", "-s", "-o", "-", "-w", "\n%{http_code}",
                               "http://127.0.0.1:\(port)/v1/messages",
                               "-H", "authorization: Bearer client-token",
                               "-H", "content-type: application/json",
                               "--data-binary", #"{"model":"claude-sonnet-4-6","messages":[]}"#])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.hasSuffix("200"), "a client still on ANTHROPIC_BASE_URL keeps working: \(result.output)")

        var state = await engine.state()
        for _ in 0..<50 where state.listener.legacyRequests == 0 {
            try await Task.sleep(for: .milliseconds(20))
            state = await engine.state()
        }
        XCTAssertEqual(state.listener.legacyRequests, 1, "but the app now knows to say so")
        XCTAssertNotNil(state.listener.lastLegacyRequestAt)
    }

    func testAnAbsoluteFormRequestIsRefused() throws {
        // Only a plaintext proxy client sends one, and the engine builds its upstream URL by
        // concatenation — it would force-unwrap nil on an absolute URI.
        let result = try curl(["--proxy", "http://127.0.0.1:\(port)", "--max-time", "10", "-s", "-o", "-", "-w", "\n%{http_code}",
                               "http://api.anthropic.com/v1/messages"])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.hasSuffix("501"), result.output)
    }

    /// Everything that is not the API host is tunnelled untouched, and that is not a corner case:
    /// the MCP servers, the telemetry endpoint and npm all inherit the proxy and arrive here.
    func testATunnelledHostGetsItsBytesBackUnchanged() async throws {
        let echo = FakeUpstream()
        try await echo.start()
        defer { Task { await echo.stop() } }

        let ca = try LocalCA.ensure(in: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "tunnel-\(UUID().uuidString)"),
                                    hosts: [ConnectAuthority.terminatedHost])
        let tunnelPort = Int.random(in: 20000..<40000)
        let server = try ProxyServer(port: tunnelPort, certificates: ca, policy: .permissive(listeningPort: tunnelPort),
                                     upstream: { echo.base }) { _ in
            HTTPResponse(status: 500, json: .object([:]))
        } onLegacyRequest: { _ in }
        try await server.start()
        defer { Task { await server.stop() } }

        // curl CONNECTs to the echo server through us; nothing of the exchange is ours to read.
        let result = try curl(["--proxy", "http://127.0.0.1:\(tunnelPort)", "--proxytunnel", "--max-time", "20",
                               "-s", "-o", "-", "-w", "\n%{http_code}",
                               "http://127.0.0.1:\(echo.server.boundPort)/v1/messages",
                               "-H", "content-type: application/json", "--data-binary", #"{"tunnelled":true}"#])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.hasSuffix("200"), result.output)
        let sent = try XCTUnwrap(echo.seen.last)
        XCTAssertEqual(String(decoding: sent.body, as: UTF8.self), #"{"tunnelled":true}"#, "the body arrives byte for byte")
        XCTAssertNil(sent.headers["authorization"], "a tunnel injects nothing of its own")
    }

    /// Remote Control's live channel. It must reach the upstream with its own headers intact and
    /// must never touch `Relay.serve`, which would strip the three headers the handshake is made of.
    func testAWebSocketUpgradeIsRelayedVerbatim() async throws {
        let standIn = UpgradeStandIn()
        try await standIn.start()
        defer { Task { await standIn.stop() } }

        let ca = try LocalCA.ensure(in: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "upgrade-\(UUID().uuidString)"),
                                    hosts: [ConnectAuthority.terminatedHost])
        let proxyPort = Int.random(in: 20000..<40000)
        let engineSawARequest = Locked(false)
        let server = try ProxyServer(port: proxyPort, certificates: ca, upstream: { standIn.base }) { _ in
            engineSawARequest.value = true
            return HTTPResponse(status: 500, json: .object([:]))
        } onLegacyRequest: { _ in }
        try await server.start()
        defer { Task { await server.stop() } }

        let result = try curl(["--proxy", "http://127.0.0.1:\(proxyPort)", "--cacert", ca.caPath.path,
                               "--max-time", "10", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                               "https://api.anthropic.com/v1/session_ingress/ws/abc",
                               "-H", "connection: Upgrade",
                               "-H", "upgrade: websocket",
                               "-H", "sec-websocket-version: 13",
                               "-H", "sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==",
                               "-H", "authorization: Bearer client-token"])
        // curl's exit code is not checked: it treats a 101 followed by a closed socket as an empty
        // reply, because it speaks HTTP and not what comes after the switch. The status line is
        // what matters, and it reaches the client.
        XCTAssertEqual(result.output, "101", "the client gets the switch, not an answer we invented")

        let seen = standIn.seenRequest.lowercased()
        XCTAssertTrue(seen.contains("get /v1/session_ingress/ws/abc"), seen)
        XCTAssertTrue(seen.contains("connection: upgrade"), "the header Relay.serve would have dropped")
        XCTAssertTrue(seen.contains("upgrade: websocket"), "the header Relay.serve would have dropped")
        XCTAssertTrue(seen.contains("authorization: bearer client-token"),
                      "the session is paired to the client's own identity; a rotated token would be refused")
        XCTAssertTrue(seen.contains("host: api.anthropic.com"), "the Host the client asked for is kept")
        XCTAssertFalse(engineSawARequest.value, "an upgrade must not reach the rotation path at all")
    }

    func testTheCertificateCoversOnlyTheAPIHost() async throws {
        let listener = await engine.state().listener
        XCTAssertFalse(listener.caFingerprint.isEmpty)
        XCTAssertNotNil(listener.caNotAfter)
        XCTAssertTrue(FileManager.default.fileExists(atPath: listener.caPath))
        // Another host through the same proxy is tunnelled, so our leaf is never offered for it.
        let result = try curl(proxyArguments + ["https://example.invalid/"])
        XCTAssertNotEqual(result.status, 0, "a tunnelled host is dialled for real and fails to resolve, rather than getting our certificate")
    }
}
