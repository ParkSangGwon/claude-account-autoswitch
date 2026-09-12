import Foundation

/// Requests served on an account since the engine started.
public struct Traffic: Codable, Sendable, Equatable {
    public var requests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheCreationTokens = 0
    public var lastUsed: Date?

    public init() {}

    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}

/// Billing beyond the plan, as the usage endpoint reports it.
public struct Overage: Sendable, Equatable, Codable {
    public var enabled: Bool
    public var usedMinor: Double?
    public var currency: String
    public var exponent: Int

    public init(enabled: Bool, usedMinor: Double?, currency: String, exponent: Int) {
        self.enabled = enabled; self.usedMinor = usedMinor; self.currency = currency; self.exponent = exponent
    }
}

public struct ProbeResult: Sendable, Equatable, Codable {
    public var at: Date
    public var error: String?
    public init(at: Date, error: String?) { self.at = at; self.error = error }
}

/// One account as the engine sees it right now: the record minus its secrets, plus everything learned at runtime.
public struct AccountStatus: Sendable, Equatable, Identifiable {
    public var id: AccountID
    public var label: String
    public var kind: CredentialKind
    public var plan: Plan
    public var rank: Int
    public var enabled: Bool
    public var organization: Organization?
    public var claudeAccountID: String?
    public var windows: Windows
    public var health: Health
    public var coolingUntil: Date?
    /// Nil when the account can take the next request.
    public var blocker: Blocker?
    public var activeSessions: Int
    public var knownSessions: Int
    public var traffic: Traffic
    public var probe: ProbeResult?
    public var overage: Overage?

    public init(id: AccountID, label: String, kind: CredentialKind, plan: Plan, rank: Int, enabled: Bool, organization: Organization?,
                claudeAccountID: String?, windows: Windows, health: Health, coolingUntil: Date?, blocker: Blocker?, activeSessions: Int,
                knownSessions: Int, traffic: Traffic, probe: ProbeResult?, overage: Overage?) {
        self.id = id; self.label = label; self.kind = kind; self.plan = plan; self.rank = rank; self.enabled = enabled
        self.organization = organization; self.claudeAccountID = claudeAccountID; self.windows = windows; self.health = health
        self.coolingUntil = coolingUntil; self.blocker = blocker; self.activeSessions = activeSessions; self.knownSessions = knownSessions
        self.traffic = traffic; self.probe = probe; self.overage = overage
    }

    public var canServe: Bool { blocker == nil }

    /// The family windows this account reports, Fable before Sonnet.
    public var familyReadings: [(family: Family, reading: WindowReading)] {
        Family.allCases.compactMap { f in windows[f.window].map { (f, $0) } }
    }
}

public struct SessionRecord: Sendable, Equatable, Identifiable {
    public var id: String
    public var active: Bool
    public var inFlight: Int
    public var requests: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var client: String?
    public var pins: [WindowKind: AccountID]
    /// Requests in a row that came back with nothing usable.
    public var starved: Int

    public init(id: String, active: Bool, inFlight: Int, requests: Int, firstSeen: Date, lastSeen: Date, client: String?, pins: [WindowKind: AccountID], starved: Int) {
        self.id = id; self.active = active; self.inFlight = inFlight; self.requests = requests; self.firstSeen = firstSeen
        self.lastSeen = lastSeen; self.client = client; self.pins = pins; self.starved = starved
    }
}

public struct ListenerInfo: Sendable, Equatable {
    public var port: Int
    public var baseURL: String
    public var startedAt: Date?
    public var version: String

    public init(port: Int, baseURL: String, startedAt: Date?, version: String) {
        self.port = port; self.baseURL = baseURL; self.startedAt = startedAt; self.version = version
    }

    public var isRunning: Bool { startedAt != nil }
}

public struct ProbeInfo: Sendable, Equatable {
    public var enabled: Bool
    public var intervalSeconds: Int
    public var lastFinishedAt: Date?

    public init(enabled: Bool, intervalSeconds: Int, lastFinishedAt: Date?) {
        self.enabled = enabled; self.intervalSeconds = intervalSeconds; self.lastFinishedAt = lastFinishedAt
    }

    public var nextRunAt: Date? { enabled ? lastFinishedAt?.addingTimeInterval(Double(max(30, intervalSeconds))) : nil }
}

/// Everything the app shows, in one value the engine produces on demand.
public struct EngineState: Sendable, Equatable {
    public var accounts: [AccountStatus]
    /// The account new requests start from.
    public var current: AccountID?
    /// Where the next request lands, once blockers and ranks are applied.
    public var next: AccountID?
    /// Where a request for each family lands (nil: nothing can serve it).
    public var familyTargets: [Family: AccountID?]
    public var sessions: [SessionRecord]
    public var rotation: Configuration.Rotation
    public var listener: ListenerInfo
    public var probe: ProbeInfo
    public var observedAt: Date

    public init(accounts: [AccountStatus], current: AccountID?, next: AccountID?, familyTargets: [Family: AccountID?], sessions: [SessionRecord],
                rotation: Configuration.Rotation, listener: ListenerInfo, probe: ProbeInfo, observedAt: Date) {
        self.accounts = accounts; self.current = current; self.next = next; self.familyTargets = familyTargets; self.sessions = sessions
        self.rotation = rotation; self.listener = listener; self.probe = probe; self.observedAt = observedAt
    }

    public func account(_ id: AccountID?) -> AccountStatus? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    public func account(labelled label: String) -> AccountStatus? { accounts.first { $0.label == label } }

    public func label(_ id: AccountID?) -> String? { account(id)?.label }

    public var currentAccount: AccountStatus? { account(current) }
    public var nextAccount: AccountStatus? { account(next) }

    /// Preference order: rank, then the order in the config.
    public var byRank: [AccountStatus] {
        accounts.enumerated().sorted { a, b in
            a.element.rank != b.element.rank ? a.element.rank < b.element.rank : a.offset < b.offset
        }.map(\.element)
    }

    /// Every account is out: requests will wait or come back 429.
    public var isExhausted: Bool { !accounts.isEmpty && accounts.allSatisfy { $0.blocker != nil } }

    /// The current account is out but traffic already moved on: ordinary rotation, not an emergency.
    public var currentMovedOn: Bool {
        guard let cur = currentAccount, cur.blocker != nil, let next else { return false }
        return next != cur.id
    }

    public var activeSessionCount: Int { sessions.filter(\.active).count }
    public var starvedMax: Int { sessions.map(\.starved).max() ?? 0 }
}
