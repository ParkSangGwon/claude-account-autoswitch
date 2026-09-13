import Foundation
import AutoSwitchCore

/// How an account arrives.
public enum AccountSource: Sendable, Equatable {
    /// The browser flow Claude Code uses; the callback lands on a listener this engine opens.
    case browser
    /// The same flow, but the user pastes `code#state` from Anthropic's page (no callback needed).
    case pasteCode
    case apiKey(String)
    /// Claude Code's own login, from the Keychain.
    case claudeCode
    case credentialsFile(String)
}

public enum AccountEvent: Sendable, Equatable {
    case line(String)
    case openURL(URL)
}

/// Signing in, importing, refreshing tokens and probing usage: everything that touches a credential.
extension Engine {
    // MARK: - adding

    /// Adds or refreshes accounts; returns how many records were written. Progress goes to `onEvent`.
    @discardableResult
    public func addAccount(_ source: AccountSource, label: String?, onEvent: @escaping @Sendable (AccountEvent) -> Void) async throws -> Int {
        switch source {
        case .browser:
            let pkce = OAuth.PKCE()
            let callback = HTTPServer(port: 0) { [weak self] request in
                guard let self else { return HTTPResponse(status: 503, json: .null) }
                return await self.handleCallback(request)
            }
            try await callback.start()
            defer { Task { await callback.stop() } }
            let redirect = "http://localhost:\(callback.boundPort)/callback"
            let url = OAuth.authorizeURL(redirectURI: redirect, pkce: pkce)
            onEvent(.line(L("Opening the browser for sign-in…")))
            onEvent(.openURL(url))
            let (code, state) = try await withTimeout(seconds: 120) { [self] in
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.setPendingCallback(pkce: pkce, cont) }
                }
            }
            return try await finishOAuth(code: code, state: state, pkce: pkce, redirect: redirect, label: label, onEvent: onEvent)
        case .pasteCode:
            let pkce = OAuth.PKCE()
            let url = OAuth.authorizeURL(redirectURI: OAuth.manualRedirectURI, pkce: pkce)
            onEvent(.line(L("Sign in on the page that opens, then paste the code it shows.")))
            onEvent(.openURL(url))
            let pasted = try await withTimeout(seconds: 600) { [self] in
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.setPendingPaste(pkce: pkce, cont) }
                }
            }
            let (code, state) = try OAuth.parseAuthCode(pasted, expectedState: pkce.state)
            return try await finishOAuth(code: code, state: state, pkce: pkce, redirect: OAuth.manualRedirectURI, label: label, onEvent: onEvent)
        case .apiKey(let key):
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("sk-ant-") else { throw EngineError.oauth(L("That does not look like an Anthropic API key")) }
            return try upsert([AccountRecord(label: label ?? "api-key", credential: .apiKey(trimmed))], onEvent: onEvent)
        case .claudeCode:
            onEvent(.line(L("Reading Claude Code's login from the Keychain…")))
            return try await finishImport(try Importers.fromKeychain(), label: label, onEvent: onEvent)
        case .credentialsFile(let path):
            return try await finishImport(try Importers.fromFile(path), label: label, onEvent: onEvent)
        }
    }

    /// The paste flow's second half: the sheet hands over what the user pasted.
    public func submitLoginCode(_ code: String) {
        guard let pending = pendingPaste else { return }
        pendingPaste = nil
        pending.continuation.resume(returning: code)
    }

    public func cancelPendingLogin() {
        pendingPaste?.continuation.resume(throwing: EngineError.cancelled); pendingPaste = nil
        pendingCallback?.continuation.resume(throwing: EngineError.cancelled); pendingCallback = nil
    }

    func setPendingPaste(pkce: OAuth.PKCE, _ cont: CheckedContinuation<String, Error>) {
        pendingPaste?.continuation.resume(throwing: EngineError.cancelled)
        pendingPaste = (pkce, cont)
    }

    func setPendingCallback(pkce: OAuth.PKCE, _ cont: CheckedContinuation<(code: String, state: String), Error>) {
        pendingCallback?.continuation.resume(throwing: EngineError.cancelled)
        pendingCallback = (pkce, cont)
    }

    /// `GET /callback?code=…&state=…` from the browser; the state is checked before anything else.
    func handleCallback(_ request: HTTPRequest) -> HTTPResponse {
        guard request.path == "/callback" else { return HTTPResponse(status: 404, json: .object(["error": .string("not found")])) }
        let items = URLComponents(string: "http://x" + request.uri)?.queryItems ?? []
        let state = items.first { $0.name == "state" }?.value
        guard let pending = pendingCallback, state == pending.pkce.state else {
            return HTTPResponse(status: 400, headers: [("content-type", "text/html; charset=utf-8")], body: .data(Data("<h2>State mismatch</h2><p>Start the sign-in again from Claude AutoSwitch.</p>".utf8)))
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            pendingCallback = nil
            pending.continuation.resume(throwing: EngineError.oauth(error))
            return HTTPResponse(status: 200, headers: [("content-type", "text/html; charset=utf-8")], body: .data(Data("<h2>Sign-in did not complete</h2><p>\(error)</p>".utf8)))
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            return HTTPResponse(status: 400, json: .object(["error": .string("no code")]))
        }
        pendingCallback = nil
        pending.continuation.resume(returning: (code, state ?? ""))
        return HTTPResponse(status: 302, headers: [("location", "https://platform.claude.com/oauth/code/success?app=claude-code")], body: .data(Data()))
    }

    private func finishOAuth(code: String, state: String, pkce: OAuth.PKCE, redirect: String, label: String?, onEvent: @escaping @Sendable (AccountEvent) -> Void) async throws -> Int {
        onEvent(.line(L("Exchanging the code for tokens…")))
        let tokens = try await OAuth.exchange(code: code, state: state, verifier: pkce.verifier, redirectURI: redirect)
        return try await finishImport(Importers.Imported(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, expiresAt: tokens.expiresAt, rateLimitTier: nil), label: label, onEvent: onEvent)
    }

    /// Identity from the profile endpoint, then the record.
    private func finishImport(_ imported: Importers.Imported, label: String?, onEvent: @escaping @Sendable (AccountEvent) -> Void) async throws -> Int {
        onEvent(.line(L("Looking up the account…")))
        var profile: OAuth.Profile?
        do { profile = try await OAuth.profile(accessToken: imported.accessToken) }
        catch { if label == nil { throw EngineError.oauth(L("Could not read the account's profile; give the account a name to add it anyway")) } }
        let record = AccountRecord(
            label: label ?? profile?.email ?? "account",
            plan: Plan(tierText: profile?.rateLimitTier ?? imported.rateLimitTier, seatText: profile?.seatTier),
            planText: profile?.rateLimitTier ?? imported.rateLimitTier,
            seatText: profile?.seatTier,
            organization: profile.map { Organization(name: $0.orgName, id: $0.orgUuid) },
            claudeAccountID: profile?.accountUuid,
            credential: .oauth(OAuthTokens(access: imported.accessToken, refresh: imported.refreshToken, expiresAt: imported.expiresAt))
        )
        let n = try upsert([record], onEvent: onEvent)
        Task { await self.probeNow() }
        return n
    }

    /// The same Claude account seen again is updated in place, keeping its id, label, rank and switch.
    @discardableResult
    func upsert(_ incoming: [AccountRecord], onEvent: @escaping @Sendable (AccountEvent) -> Void) throws -> Int {
        try update { c in
            for new in incoming {
                if let i = c.accounts.firstIndex(where: { $0.sameIdentity(as: new) }) {
                    var row = c.accounts[i]
                    row.credential = new.credential
                    if new.plan != .unknown { row.plan = new.plan; row.planText = new.planText; row.seatText = new.seatText }
                    if new.organization != nil { row.organization = new.organization }
                    if new.claudeAccountID != nil { row.claudeAccountID = new.claudeAccountID }
                    c.accounts[i] = row
                    onEvent(.line(L("Updated %@", row.label)))
                } else {
                    c.accounts.append(new)
                    onEvent(.line(L("Added %@", new.label)))
                }
            }
        }
        return incoming.count
    }

    public func removeAccount(_ id: AccountID) throws {
        try update { c in c.accounts.removeAll { $0.id == id } }
    }

    // MARK: - tokens

    /// A fresh access token for an account: refreshed when within the margin, forced after a 401.
    /// One refresh per account at a time; a refresh token the server rejected is never sent again.
    @discardableResult
    func ensureFreshToken(_ id: AccountID, force: Bool = false) async -> Bool {
        guard let i = runtimeIndex(id) else { return false }
        guard let tokens = runtime[i].oauthTokens else { return runtime[i].secret != nil }
        guard let refresh = tokens.refresh else { return true }
        if deadRefreshTokens.contains(refresh) { runtime[i].health = .needsLogin; return false }
        guard force || OAuth.isExpiringSoon(tokens.expiresAt) else { return true }
        guard !refreshInFlight.contains(id) else {
            while refreshInFlight.contains(id) { try? await Task.sleep(for: .milliseconds(100)) }
            return runtimeIndex(id).map { runtime[$0].health != .needsLogin } ?? false
        }
        refreshInFlight.insert(id)
        defer { refreshInFlight.remove(id) }
        do {
            let pair = try await OAuth.refresh(refreshToken: refresh)
            guard let j = runtimeIndex(id) else { return false }
            let fresh = OAuthTokens(access: pair.accessToken, refresh: pair.refreshToken ?? refresh, expiresAt: pair.expiresAt)
            runtime[j].record.credential = .oauth(fresh)
            if runtime[j].health == .needsLogin { runtime[j].health = .ok }
            try? update { c in
                if let k = c.index(of: id) { c.accounts[k].credential = .oauth(fresh) }
            }
            return true
        } catch EngineError.oauthRejected(let status, _) where [400, 401, 403].contains(status) {
            deadRefreshTokens.insert(refresh)
            if let j = runtimeIndex(id) { runtime[j].health = .needsLogin }
            return false
        } catch {
            return runtimeIndex(id).map { runtime[$0].secret != nil } ?? false
        }
    }

    // MARK: - probe

    func startProbeLoop() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.probeNow()
                let seconds = await self.probeInterval
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    var probeInterval: TimeInterval {
        let s = Double(configuration.quota.refreshEverySeconds)
        return s <= 0 ? 3600 : max(30, s)
    }

    /// The usage endpoint for every enabled subscription account, so idle accounts have numbers too.
    public func probeNow() async {
        guard configuration.quota.refreshEverySeconds > 0 else { return }
        for id in runtime.filter({ $0.record.kind == .subscription && $0.record.enabled }).map(\.id) {
            guard await ensureFreshToken(id), let i = runtimeIndex(id), let token = runtime[i].oauthTokens?.access else {
                if let i = runtimeIndex(id) { runtime[i].probe = ProbeResult(at: Date(), error: L("no usable token")) }
                continue
            }
            do {
                let usage = try await OAuth.usage(accessToken: token)
                guard let j = runtimeIndex(id) else { continue }
                absorb(usage, into: j)
                runtime[j].probe = ProbeResult(at: Date(), error: nil)
                if runtime[j].record.plan == .unknown, let p = try? await OAuth.profile(accessToken: token), let k = runtimeIndex(id) {
                    runtime[k].record.plan = Plan(tierText: p.rateLimitTier, seatText: p.seatTier)
                    runtime[k].record.planText = p.rateLimitTier
                    runtime[k].record.seatText = p.seatTier
                    let plan = runtime[k].record.plan, planText = p.rateLimitTier, seatText = p.seatTier
                    try? update { c in
                        if let m = c.index(of: id) { c.accounts[m].plan = plan; c.accounts[m].planText = planText; c.accounts[m].seatText = seatText }
                    }
                }
            } catch EngineError.oauthRejected(let status, _) where status == 401 {
                _ = await ensureFreshToken(id, force: true)
                if let j = runtimeIndex(id) { runtime[j].probe = ProbeResult(at: Date(), error: "401") }
            } catch {
                if let j = runtimeIndex(id) { runtime[j].probe = ProbeResult(at: Date(), error: String(describing: error)) }
            }
        }
        lastProbeAt = Date()
        saveObservations()
    }

    func absorb(_ usage: OAuth.Usage, into i: Int, now: Date = Date()) {
        if let u = usage.fiveHour.utilization { runtime[i].windows[.session] = WindowReading(used: u, resetsAt: usage.fiveHour.resetAt, seenAt: now) }
        if let u = usage.sevenDay.utilization { runtime[i].windows[.weekly] = WindowReading(used: u, resetsAt: usage.sevenDay.resetAt, seenAt: now) }
        for (name, b) in usage.scopedWeekly {
            guard let family = Family(rawValue: name), let u = b.utilization else { continue }
            runtime[i].windows[family.window] = WindowReading(used: u, resetsAt: b.resetAt, seenAt: now)
        }
    }
}
