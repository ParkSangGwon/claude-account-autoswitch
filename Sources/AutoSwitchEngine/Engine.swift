import Foundation
import AutoSwitchCore

public enum EngineError: Error, Sendable, Equatable {
    case portInUse(Int)
    case listen(String)
    case config(String)
    case oauth(String)
    case oauthRejected(status: Int, body: String)
    case importFailed(String)
    case noSuchAccount
    case timedOut
    case cancelled
    case configUnreadable

    public var message: String {
        switch self {
        case .portInUse(let p): return L("Port %d is already in use", p)
        case .listen(let why): return L("Could not listen: %@", why)
        case .config(let why): return L("Config error: %@", why)
        case .oauth(let why): return why
        case .oauthRejected(let status, _): return L("Anthropic answered HTTP %d", status)
        case .importFailed(let why): return why
        case .noSuchAccount: return L("No such account")
        case .timedOut: return L("Timed out waiting for the sign-in")
        case .cancelled: return L("Cancelled")
        case .configUnreadable: return L("Not saving — the config file could not be read. Fix the file first so the accounts in it are not lost.")
        }
    }
}

/// The proxy. Owns the configuration, the accounts and what has been learned about them,
/// the listener, and the choice of account for every request. The app reads it through
/// `state()`; nothing goes over HTTP between the two.
public actor Engine {
    nonisolated public let store: ConfigStore
    nonisolated public let version: String
    public private(set) var configuration = Configuration.defaults
    var runtime: [AccountRuntime] = []
    /// The account new requests start from.
    var cursor: AccountID?
    var affinity = Affinity()
    var startedAt: Date?
    private var listener: HTTPServer?
    public private(set) var lastError: EngineError?
    /// The document on disk could not be parsed. Every write is refused while this stands, so a file
    /// the app never read is not replaced by the empty defaults it fell back to.
    public private(set) var loadFailure: ConfigError?
    /// A paste-the-code login waiting for its code, and a browser login waiting for its callback.
    var pendingPaste: (pkce: OAuth.PKCE, continuation: CheckedContinuation<String, Error>)?
    var pendingCallback: (pkce: OAuth.PKCE, continuation: CheckedContinuation<(code: String, state: String), Error>)?
    var refreshInFlight: Set<AccountID> = []
    var deadRefreshTokens: Set<String> = []
    var probeTask: Task<Void, Never>?
    var lastProbeAt: Date?
    private var loaded = false

    public init(store: ConfigStore, version: String) {
        self.store = store
        self.version = version
    }

    // MARK: - configuration

    /// Read the document, writing the defaults on first launch.
    public func load() throws {
        do {
            adopt(try store.load())
        } catch ConfigError.notFound {
            try store.save(Configuration.defaults)
            adopt(Configuration.defaults)
        } catch let failure as ConfigError {
            loadFailure = failure
            throw failure
        }
        loadFailure = nil
        loaded = true
    }

    /// A write while the document is unreadable would put the app's in-memory defaults — no accounts,
    /// no tokens — over a file that still holds them.
    private func refuseWhileUnreadable() throws {
        if loadFailure != nil { throw EngineError.configUnreadable }
    }

    /// Rebuild the runtime from a document, keeping what was learned about accounts that stay.
    /// On the first adoption there is nothing to keep, so the document's own observations stand in.
    func adopt(_ c: Configuration) {
        configuration = c
        let old = runtime
        runtime = c.accounts.map { record in
            var r = AccountRuntime(record: record)
            if let prev = old.first(where: { $0.id == record.id || $0.record.sameIdentity(as: record) }) { r.inherit(from: prev) }
            else if let seen = c.observed.windows(of: record.id) { r.windows = seen }
            return r
        }
        affinity.retain(Set(runtime.map(\.id)))
        let before = cursor
        if cursor == nil { cursor = c.observed.lastActive }
        if let cur = cursor, !runtime.contains(where: { $0.id == cur }) { cursor = nil }
        let now = Date()
        sweep(now: now)
        if cursor == nil || !canServe(cursor!, now: now) { cursor = bestCandidate(excluding: [], now: now) ?? cursor }
        // Quitting cannot be relied on to write, so a cursor settled here is written now.
        if cursor != before { saveObservations() }
    }

    /// Write back what the engine has learned, so the next launch starts where this one left off
    /// instead of sending its first request to an account it has no numbers for. The cursor moving
    /// and a finished probe are the moments worth a write; a failed one costs freshness, nothing in flight.
    func saveObservations() {
        guard loadFailure == nil else { return }
        let observed = Configuration.Observed(
            lastActive: cursor,
            accounts: runtime.compactMap { $0.windows.isEmpty ? nil : .init(id: $0.id, windows: $0.windows) }
        )
        guard observed != configuration.observed else { return }
        configuration.observed = observed
        try? store.save(configuration)
    }

    /// The settings screens' write path: the document is saved, then applied live.
    public func update(_ mutate: @Sendable (inout Configuration) throws -> Void) throws {
        try refuseWhileUnreadable()
        var c = configuration
        try mutate(&c)
        try store.save(c)
        adopt(c)
    }

    /// The raw editor's path: a whole document at once.
    public func replace(_ c: Configuration) throws {
        try store.save(c)
        adopt(c)
        loadFailure = nil
    }

    /// Re-read the file (something else edited it); returns how many accounts appeared.
    public func reloadFromDisk() throws -> Int {
        let before = Set(runtime.map(\.id))
        do {
            adopt(try store.load())
        } catch let failure as ConfigError {
            loadFailure = failure
            throw failure
        }
        loadFailure = nil
        return runtime.filter { !before.contains($0.id) }.count
    }

    public var port: Int { configuration.effectivePort }
    public var baseURL: String { configuration.api.baseURL }

    // MARK: - lifecycle

    public var isRunning: Bool { listener != nil }

    public func start() async throws {
        if !loaded { try load() }
        if listener != nil { return }
        let l = HTTPServer(port: port) { [weak self] request in
            guard let self else { return HTTPResponse(status: 503, json: .object(["error": .string("engine stopped")])) }
            return await self.handle(request)
        }
        do {
            try await l.start()
        } catch let e as EngineError {
            lastError = e
            throw e
        }
        listener = l
        startedAt = Date()
        lastError = nil
        if ProcessInfo.processInfo.environment["AUTOSWITCH_DEBUG_DEMO_QUOTA"] != nil { seedDemoWindows() } else { startProbeLoop() }
    }

    public func stop() async {
        probeTask?.cancel()
        probeTask = nil
        saveObservations()
        await listener?.stop()
        listener = nil
        startedAt = nil
    }

    /// A port near the configured one that nothing is listening on, or nil if the neighbourhood is full.
    public func freePortNearby() -> Int? {
        let configured = configuration.effectivePort
        return (1...64).lazy.map { configured + $0 }.first { $0 <= 65535 && HTTPServer.isFree($0) }
    }

    /// Move the listener to a port that is actually free and write it to the document.
    public func moveToFreePort() async throws -> Int {
        guard let port = freePortNearby() else { throw EngineError.portInUse(configuration.effectivePort) }
        try update { $0.listen.port = port }
        await stop()
        try await start()
        return port
    }

    /// Bind to a new port when the config moved it.
    public func restartIfPortChanged() async throws {
        guard let l = listener, l.port != port else { return }
        await stop()
        try await start()
    }

    /// `AUTOSWITCH_DEBUG_DEMO_QUOTA=1`: plausible windows on every account, for screenshots and UI work without a real login.
    func seedDemoWindows(now: Date = Date()) {
        let samples: [(Double, Double, Double, Double)] = [(0.37, 0.34, 0.05, 0.12), (0.29, 0.61, 0.88, 0.40), (0.72, 0.18, 0.20, 0.55)]
        for i in runtime.indices {
            let s = samples[i % samples.count]
            let week = now.addingTimeInterval(Double(86_400 * (i + 1) + 5_000))
            // Session resets chosen so the demo shows one window that keeps pace and one that runs ahead of the clock.
            runtime[i].windows[.session] = WindowReading(used: s.0, resetsAt: now.addingTimeInterval(Double(11_880 + i * 3_420)), seenAt: now)
            runtime[i].windows[.weekly] = WindowReading(used: s.1, resetsAt: week, seenAt: now)
            runtime[i].windows[.weeklyFable] = WindowReading(used: s.2, resetsAt: week, seenAt: now)
            runtime[i].windows[.weeklySonnet] = WindowReading(used: s.3, resetsAt: week, seenAt: now)
            runtime[i].traffic.requests = 120 * (i + 1)
            runtime[i].probe = ProbeResult(at: now, error: nil)
        }
        lastProbeAt = now
    }

    // MARK: - what the app reads

    public func state(now: Date = Date()) -> EngineState {
        sweep(now: now)
        var targets: [Family: AccountID?] = [:]
        for f in Family.allCases where runtime.contains(where: { $0.windows[f.window] != nil }) {
            targets[f] = choose(model: "claude-\(f.rawValue)", session: nil, excluding: [], now: now)
        }
        let accounts = runtime.map { r in
            r.status(blocker: blocker(of: r, now: now), activeSessions: affinity.activeCount(pinnedTo: r.id, now: now), knownSessions: affinity.knownCount(pinnedTo: r.id))
        }
        return EngineState(
            accounts: accounts,
            current: cursor,
            next: nextTarget(now: now),
            familyTargets: targets,
            sessions: affinity.records(now: now),
            rotation: configuration.rotation,
            listener: ListenerInfo(port: port, baseURL: baseURL, startedAt: startedAt, version: version),
            probe: ProbeInfo(enabled: configuration.quota.refreshEverySeconds > 0, intervalSeconds: configuration.quota.refreshEverySeconds, lastFinishedAt: lastProbeAt),
            observedAt: now
        )
    }

    /// Make an account the one new requests start from, whether or not rotation would pick it.
    public func switchTo(_ id: AccountID) -> SwitchOutcome {
        guard let r = runtime.first(where: { $0.id == id }) else { return .failed(L("No such account")) }
        cursor = id
        saveObservations()
        let now = Date()
        let blocked = blocker(of: r, now: now)
        // The cursor moved, but a strictly better rank still wins the next request; say so rather
        // than report a switch that the very next reply undoes.
        if blocked == nil, let next = nextTarget(now: now), next != id {
            return .switched(to: r.label, blocker: nil, outrankedBy: runtime.first { $0.id == next }?.label ?? next.rawValue)
        }
        return .switched(to: r.label, blocker: blocked)
    }

    // MARK: - listener

    static let healthPath = "/_autoswitch/health"

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == "GET", request.path == Engine.healthPath {
            return HTTPResponse(status: 200, json: .object([
                "ok": .bool(true), "version": .string(version), "port": .number(Double(port)),
                "accounts": .number(Double(runtime.count)), "startedAt": startedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            ]))
        }
        return await serve(request)
    }
}

/// Bound the wait for a code; the pending continuation is what the timeout cancels.
func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw EngineError.timedOut }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
