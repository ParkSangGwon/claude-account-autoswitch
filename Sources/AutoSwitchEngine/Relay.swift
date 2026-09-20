import Foundation
import AutoSwitchCore

/// Serving a request: pick an account, put its credential on the wire, stream the reply back,
/// learn from the reply's headers, and move to another account when this one is refused.
extension Engine {
    /// Never forwarded: hop-by-hop headers, the client's own credential, and what the outbound request re-derives.
    static let droppedOutbound: Set<String> = ["host", "connection", "keep-alive", "transfer-encoding", "te", "trailer", "upgrade", "proxy-authorization", "proxy-authenticate", "content-length", "accept-encoding", "authorization", "x-api-key"]
    /// Never relayed back: connection details and encodings the URL loader already undid.
    static let droppedInbound: Set<String> = ["connection", "keep-alive", "transfer-encoding", "upgrade", "proxy-connection", "te", "trailer", "content-encoding", "content-length"]
    /// Paths where the client's own credential must go through untouched.
    static let clientCredentialPaths = ["/v1/code/", "/api/oauth/"]
    static let maxBodyBytes = 64 * 1024 * 1024

    /// What one attempt on one account decided.
    private enum Verdict {
        case deliver
        case retryElsewhere
        case retrySameAfterRefresh
    }

    func serve(_ request: HTTPRequest) async -> HTTPResponse {
        if request.body.count > Engine.maxBodyBytes { return apiError(413, "request body over \(Engine.maxBodyBytes) bytes") }
        if Engine.clientCredentialPaths.contains(where: { request.path.hasPrefix($0) }) { return await relayAsClient(request) }

        let session = Affinity.sessionID(of: request)
        let model = (try? JSON.parse(request.body))?["model"].string
        let window = WindowKind.weekly(for: model)
        if let session { affinity.begin(session, client: request.header("user-agent").map { String($0.prefix(48)) }) }
        var tried: Set<AccountID> = []
        var refreshed: Set<AccountID> = []
        var hopped = false
        /// Why the last account dropped out without an answer, when nothing could be reached.
        var unreachable: String?
        let deadline = Date().addingTimeInterval(Double(configuration.rotation.waitWhenExhaustedSeconds))
        var lastStatus = 0

        defer { if let session { affinity.end(session, usable: lastStatus > 0 && lastStatus < 500 && lastStatus != 429 && lastStatus != 401) } }

        while true {
            let now = Date()
            sweepAccounts(now: now)
            guard let id = choose(model: model, session: session, excluding: tried, now: now) else {
                // Nothing can serve: wait while the config allows, then answer the way Anthropic would.
                let relief = earliestRelief(model: model, now: now)
                if now.addingTimeInterval(min(relief, 60)) < deadline {
                    try? await Task.sleep(for: .seconds(min(relief, 60)))
                    tried.removeAll()
                    unreachable = nil
                    continue
                }
                // Nobody refused this request — it never arrived. Calling that a rate limit sends
                // the client, and whoever reads its logs, after a quota that is not the problem.
                if let why = unreachable { lastStatus = 502; return apiError(502, L("Upstream unreachable: %@", why)) }
                lastStatus = 429
                return apiError(429, L("every account is out of rotation"), headers: [("retry-after", String(Int(relief)))], type: "rate_limit_error")
            }
            guard await ensureFreshToken(id), let i = runtimeIndex(id), let secret = runtime[i].secret else {
                tried.insert(id); continue
            }
            let account = runtime[i]
            let outbound = outboundRequest(request, account: account, secret: secret)

            let reply: UpstreamReply
            do {
                reply = try await Upstream.send(outbound)
            } catch {
                // A network failure is this account's problem only if the next one fares better; try once more elsewhere.
                tried.insert(id)
                unreachable = error.localizedDescription
                continue
            }
            guard let j = runtimeIndex(id) else { lastStatus = 502; return apiError(502, "account list changed") }
            Signals.absorb(reply.headers, into: &runtime[j].windows)
            lastStatus = reply.status

            let verdict: Verdict
            switch reply.status {
            case 429:
                switch Signals.refusal(reply.headers) {
                case .sharedWindow: runtime[j].coolDown(seconds: min(max(Signals.retryAfter(reply.headers), 1), 3600))
                case .fableWindow: runtime[j].windows.refusedAt = Date()
                // No window named: step aside for this request only. A minute of exile on a burst
                // costs both accounts at once, because whatever refused this one refuses its sibling.
                case .plain: runtime[j].noteUnattributedRefusal(retryAfter: Signals.retryAfter(reply.headers, fallback: 5))
                }
                verdict = .retryElsewhere
            case 401:
                if account.record.kind == .subscription, !refreshed.contains(id) {
                    refreshed.insert(id)
                    verdict = await ensureFreshToken(id, force: true) ? .retrySameAfterRefresh : .retryElsewhere
                } else {
                    verdict = .retryElsewhere
                }
            case 403:
                verdict = .retryElsewhere
            case 500...599 where !hopped:
                hopped = true
                verdict = .retryElsewhere
            default:
                if reply.status < 400 {
                    runtime[j].warmUp()
                    // Rotation moved: worth a write, and it carries the fresh windows with it.
                    if cursor != id { cursor = id; saveObservations() }
                    if let session { affinity.pin(session, window: window, to: id) }
                    runtime[j].traffic.requests += 1
                    runtime[j].traffic.lastUsed = Date()
                }
                verdict = .deliver
            }

            switch verdict {
            case .retrySameAfterRefresh:
                continue
            case .retryElsewhere:
                tried.insert(id)
                if choose(model: model, session: nil, excluding: tried, now: Date()) != nil { continue }
                // Nothing left to try. `waitWhenExhaustedSeconds` applies here too: the loop head
                // only sees requests that arrive with every account already out, and a request
                // refused on its way through deserves the same wait before it gives up.
                let relief = earliestRelief(model: model, now: Date())
                if Date().addingTimeInterval(min(relief, 60)) < deadline {
                    try? await Task.sleep(for: .seconds(min(relief, 60)))
                    tried.removeAll()
                    unreachable = nil
                    continue
                }
                return deliver(reply, account: id, model: model)
            case .deliver:
                return deliver(reply, account: id, model: model)
            }
        }
    }

    /// The client's request, re-addressed to the upstream with the account's credential in place of the client's.
    private func outboundRequest(_ request: HTTPRequest, account: AccountRuntime, secret: String) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL + request.uri)!)
        req.httpMethod = request.method
        req.timeoutInterval = 120
        for (k, v) in request.headers where !Engine.droppedOutbound.contains(k.lowercased()) { req.addValue(v, forHTTPHeaderField: k) }
        switch account.record.credential {
        case .apiKey: req.setValue(secret, forHTTPHeaderField: "x-api-key")
        case .oauth: req.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
        }
        req.httpBody = Engine.rename(claudeAccountIDIn: request.body, to: account.record.claudeAccountID)
        return req
    }

    /// Stream the upstream reply to the client, counting tokens as the events go by, with the
    /// allowance headers restated for the rotation rather than for the account that answered.
    private func deliver(_ reply: UpstreamReply, account: AccountID, model: String?) -> HTTPResponse {
        let kept = reply.headers.filter { !Engine.droppedInbound.contains($0.0.lowercased()) }
        let headers = Signals.rewrite(kept, as: fleetAllowance(model: model, now: Date()))
        let isSSE = reply.headers.contains { $0.0.caseInsensitiveCompare("content-type") == .orderedSame && $0.1.contains("text/event-stream") }
        let engine = self
        let stream = AsyncStream<Data> { continuation in
            let task = Task {
                var meter = UsageMeter()
                var whole = Data()
                do {
                    for try await chunk in reply.body {
                        continuation.yield(chunk)
                        if isSSE { meter.feed(chunk) } else if whole.count < 1_048_576 { whole.append(chunk) }
                    }
                } catch {}
                continuation.finish()
                let counts = isSSE ? meter.counts : UsageMeter.counts(inBody: whole)
                if !counts.isEmpty { await engine.record(counts, for: account) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return HTTPResponse(status: reply.status, headers: headers, body: .stream(stream))
    }

    private func relayAsClient(_ request: HTTPRequest) async -> HTTPResponse {
        var req = URLRequest(url: URL(string: baseURL + request.uri)!)
        req.httpMethod = request.method
        req.timeoutInterval = 120
        let dropped = Engine.droppedOutbound.subtracting(["authorization"])
        for (k, v) in request.headers where !dropped.contains(k.lowercased()) { req.addValue(v, forHTTPHeaderField: k) }
        req.httpBody = request.body
        do {
            let reply = try await Upstream.send(req)
            let headers = reply.headers.filter { !Engine.droppedInbound.contains($0.0.lowercased()) }
            let stream = AsyncStream<Data> { continuation in
                let task = Task {
                    do { for try await chunk in reply.body { continuation.yield(chunk) } } catch {}
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return HTTPResponse(status: reply.status, headers: headers, body: .stream(stream))
        } catch {
            return apiError(502, L("Upstream unreachable: %@", error.localizedDescription))
        }
    }

    func record(_ counts: UsageMeter.Counts, for id: AccountID) {
        guard let i = runtimeIndex(id) else { return }
        runtime[i].traffic.inputTokens += counts.input
        runtime[i].traffic.outputTokens += counts.output
        runtime[i].traffic.cacheReadTokens += counts.cacheRead
        runtime[i].traffic.cacheCreationTokens += counts.cacheCreation
    }

    /// Claude Code names its account inside `metadata.user_id`; the upstream must see the account whose token it gets.
    static func rename(claudeAccountIDIn body: Data, to uuid: String?) -> Data {
        guard let uuid, uuid.count == 36, let text = String(data: body, encoding: .utf8), let range = text.range(of: "account_uuid") else { return body }
        // The value follows the key inside the stringified metadata: `\"account_uuid\":\"<36 chars>\"`.
        let tail = text[range.upperBound...]
        guard let q = tail.firstIndex(where: { $0.isHexDigit }), tail.distance(from: q, to: tail.endIndex) >= 36 else { return body }
        let end = tail.index(q, offsetBy: 36)
        let old = tail[q..<end]
        guard old.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return body }
        var out = text
        out.replaceSubrange(q..<end, with: uuid)
        return Data(out.utf8)
    }

    func apiError(_ status: Int, _ message: String, headers: [(String, String)] = [], type: String = "api_error") -> HTTPResponse {
        var r = HTTPResponse(status: status, json: .object(["type": .string("error"), "error": .object(["type": .string(type), "message": .string(message)])]))
        r.headers += headers
        return r
    }
}
