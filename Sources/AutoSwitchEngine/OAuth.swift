import Foundation
import CryptoKit
import AutoSwitchCore

/// The Claude Code OAuth client, spoken the way Claude Code speaks it: PKCE against claude.ai,
/// tokens from platform.claude.com, identity and usage from api.anthropic.com.
enum OAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    struct Endpoints: Sendable {
        var token = URL(string: "https://platform.claude.com/v1/oauth/token")!
        var profile = URL(string: "https://api.anthropic.com/api/oauth/profile")!
        var usage = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    }
    private static let endpointsLock = NSLock()
    nonisolated(unsafe) private static var _endpoints = Endpoints()
    /// Where the calls go; tests point this at a loopback fake.
    static var endpoints: Endpoints {
        get { endpointsLock.lock(); defer { endpointsLock.unlock() }; return _endpoints }
        set { endpointsLock.lock(); _endpoints = newValue; endpointsLock.unlock() }
    }
    static var tokenURL: URL { endpoints.token }
    static var profileURL: URL { endpoints.profile }
    static var usageURL: URL { endpoints.usage }
    static let scopes = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
    /// The paste-the-code flow lands on Anthropic's own page, which shows `code#state`.
    static let manualRedirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let betaHeader = "oauth-2025-04-20"
    /// A token is refreshed this long before it expires.
    static let refreshMargin: TimeInterval = 300

    struct PKCE: Sendable {
        let verifier: String
        let challenge: String
        let state: String

        init() {
            verifier = OAuth.base64url(OAuth.randomBytes(32))
            challenge = OAuth.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
            state = OAuth.base64url(OAuth.randomBytes(32))
        }
    }

    struct TokenPair: Sendable, Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date
    }

    struct Profile: Sendable, Equatable {
        var accountUuid: String?
        var email: String?
        var orgUuid: String?
        var orgName: String?
        var rateLimitTier: String?
        var seatTier: String?
    }

    struct Usage: Sendable {
        var fiveHour: (utilization: Double?, resetAt: Date?)
        var sevenDay: (utilization: Double?, resetAt: Date?)
        /// family (lower-cased display name) → weekly bucket, from the `limits` array.
        var scopedWeekly: [String: (utilization: Double?, resetAt: Date?)]
    }

    static func authorizeURL(redirectURI: String, pkce: PKCE) -> URL {
        var c = URLComponents(string: authorizeURL)!
        c.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return c.url!
    }

    /// What the user pastes: the whole callback URL, `code#state`, or a bare code.
    static func parseAuthCode(_ input: String, expectedState: String) throws -> (code: String, state: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("http"), let c = URLComponents(string: text) {
            let code = c.queryItems?.first { $0.name == "code" }?.value ?? ""
            let state = c.queryItems?.first { $0.name == "state" }?.value ?? expectedState
            guard !code.isEmpty else { throw EngineError.oauth(L("No code in the pasted URL")) }
            guard state == expectedState else { throw EngineError.oauth(L("OAuth state mismatch")) }
            return (code, state)
        }
        if let hash = text.firstIndex(of: "#") {
            let code = String(text[..<hash]).trimmingCharacters(in: .whitespaces)
            let state = String(text[text.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            guard state == expectedState else { throw EngineError.oauth(L("OAuth state mismatch")) }
            return (code, state)
        }
        guard !text.isEmpty else { throw EngineError.oauth(L("No code")) }
        return (text, expectedState)
    }

    static func exchange(code: String, state: String, verifier: String, redirectURI: String, session: URLSession = Upstream.session) async throws -> TokenPair {
        let body: JSON = .object(["code": .string(code), "state": .string(state), "grant_type": .string("authorization_code"),
                                  "client_id": .string(clientID), "redirect_uri": .string(redirectURI), "code_verifier": .string(verifier)])
        return try await token(body: body, previousRefresh: nil, session: session)
    }

    static func refresh(refreshToken: String, session: URLSession = Upstream.session) async throws -> TokenPair {
        let body: JSON = .object(["grant_type": .string("refresh_token"), "refresh_token": .string(refreshToken), "client_id": .string(clientID)])
        return try await token(body: body, previousRefresh: refreshToken, session: session)
    }

    private static func token(body: JSON, previousRefresh: String?, session: URLSession) async throws -> TokenPair {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "accept")
        req.httpBody = Data(body.pretty().utf8)
        req.timeoutInterval = 30
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EngineError.oauthRejected(status: status, body: String(decoding: data.prefix(300), as: UTF8.self)) }
        let json = try JSON.parse(data)
        return try tokenPair(from: json, previousRefresh: previousRefresh)
    }

    static func tokenPair(from json: JSON, previousRefresh: String?, now: Date = Date()) throws -> TokenPair {
        guard let access = json["access_token"].string, !access.isEmpty else { throw EngineError.oauth(L("The token reply carried no access token")) }
        let refresh = json["refresh_token"].string.flatMap { $0.isEmpty ? nil : $0 } ?? previousRefresh
        let expiresAt: Date
        if let raw = json["expires_at"].double {
            expiresAt = Date(timeIntervalSince1970: raw > 1e12 ? raw / 1000 : raw)
        } else if let seconds = json["expires_in"].double {
            expiresAt = now.addingTimeInterval(seconds)
        } else {
            expiresAt = now.addingTimeInterval(3600)
        }
        return TokenPair(accessToken: access, refreshToken: refresh, expiresAt: expiresAt)
    }

    static func isExpiringSoon(_ expiresAt: Date?, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < refreshMargin
    }

    static func profile(accessToken: String, session: URLSession = Upstream.session) async throws -> Profile {
        var req = URLRequest(url: profileURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EngineError.oauthRejected(status: status, body: "profile") }
        let j = try JSON.parse(data)
        return Profile(accountUuid: j["account"]["uuid"].string, email: j["account"]["email"].string,
                       orgUuid: j["organization"]["uuid"].string, orgName: j["organization"]["name"].string,
                       rateLimitTier: j["organization"]["rate_limit_tier"].string, seatTier: j["organization"]["seat_tier"].string)
    }

    static func usage(accessToken: String, session: URLSession = Upstream.session) async throws -> Usage {
        var req = URLRequest(url: usageURL)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "authorization")
        req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.timeoutInterval = 15
        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw EngineError.oauthRejected(status: status, body: "usage") }
        return parseUsage(try JSON.parse(data))
    }

    /// `utilization` arrives in whole percents; resets as RFC 3339 or epoch (seconds or ms).
    static func parseUsage(_ j: JSON) -> Usage {
        func bucket(_ b: JSON) -> (utilization: Double?, resetAt: Date?) {
            let pct = b["utilization"].double ?? b["used_percentage"].double ?? b["percent"].double
            return (pct.map { $0 / 100 }, b["resets_at"].date)
        }
        var scoped: [String: (utilization: Double?, resetAt: Date?)] = [:]
        for limit in j["limits"].array ?? [] where limit["group"].string == "weekly" {
            if let name = limit["scope"]["model"]["display_name"].string?.lowercased(), !name.isEmpty { scoped[name] = bucket(limit) }
        }
        if scoped["sonnet"] == nil, j["seven_day_sonnet"].object != nil { scoped["sonnet"] = bucket(j["seven_day_sonnet"]) }
        return Usage(fiveHour: bucket(j["five_hour"]), sevenDay: bucket(j["seven_day"]), scopedWeekly: scoped)
    }

    static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        return d
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
