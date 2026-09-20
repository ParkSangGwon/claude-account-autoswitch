import Foundation
import AutoSwitchCore

/// Claude Code sessions seen on the listener: which account each one sticks to per weekly window, and how busy it is.
struct Affinity: Sendable {
    static let knownTTL: TimeInterval = 3600
    static let activeTTL: TimeInterval = 120
    static let capacity = 10_000
    static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z0-9._-]{1,128}$")

    struct Session: Sendable {
        var pins: [WindowKind: AccountID] = [:]
        /// The account that served this session last, which a window it has no pin on yet follows.
        var last: AccountID?
        var firstSeen: Date
        var lastSeen: Date
        var requests = 0
        var inFlight = 0
        var starved = 0
        var client: String?
    }

    private(set) var sessions: [String: Session] = [:]

    static func sessionID(of request: HTTPRequest) -> String? {
        guard let raw = request.header("x-claude-code-session-id") ?? request.header("session-id") else { return nil }
        return idPattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) != nil ? raw : nil
    }

    mutating func begin(_ id: String, client: String?, now: Date = Date()) {
        if sessions[id] == nil {
            if sessions.count >= Self.capacity, let oldest = sessions.min(by: { $0.value.lastSeen < $1.value.lastSeen })?.key { sessions.removeValue(forKey: oldest) }
            sessions[id] = Session(firstSeen: now, lastSeen: now)
        }
        sessions[id]?.inFlight += 1
        sessions[id]?.lastSeen = now
        if let client { sessions[id]?.client = client }
    }

    mutating func end(_ id: String, usable: Bool, now: Date = Date()) {
        guard var s = sessions[id] else { return }
        s.inFlight = max(0, s.inFlight - 1)
        s.requests += 1
        s.lastSeen = now
        s.starved = usable ? 0 : s.starved + 1
        sessions[id] = s
    }

    mutating func pin(_ id: String, window: WindowKind, to account: AccountID) {
        sessions[id]?.pins[window] = account
        sessions[id]?.last = account
    }

    func pin(_ id: String?, window: WindowKind) -> AccountID? { id.flatMap { sessions[$0]?.pins[window] } }

    /// A window this session has not been pinned on follows wherever it was last served. Reading
    /// any of its pins instead would pick whichever the dictionary happened to hand over first,
    /// so the same session could be routed somewhere else on a request that changed nothing.
    func anyPin(_ id: String?) -> AccountID? { id.flatMap { sessions[$0]?.last } }

    /// Every session already running follows a switch made by hand. A pin outlives the cursor,
    /// so without this the account the person picked would take new sessions only, and the
    /// terminal they made the switch for would carry on where it was.
    mutating func repin(to account: AccountID) {
        for (id, var s) in sessions where !s.pins.isEmpty || s.last != nil {
            s.pins = s.pins.mapValues { _ in account }
            s.last = account
            sessions[id] = s
        }
    }

    /// Accounts that left the config take their pins with them.
    mutating func retain(_ ids: Set<AccountID>) {
        for (id, var s) in sessions {
            s.pins = s.pins.filter { ids.contains($0.value) }
            if let last = s.last, !ids.contains(last) { s.last = nil }
            sessions[id] = s
        }
    }

    mutating func expire(now: Date = Date()) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastSeen) < Self.knownTTL }
    }

    func isActive(_ s: Session, now: Date) -> Bool { s.inFlight > 0 || now.timeIntervalSince(s.lastSeen) < Self.activeTTL }

    func activeCount(pinnedTo account: AccountID, now: Date = Date()) -> Int {
        sessions.values.filter { isActive($0, now: now) && $0.pins.values.contains(account) }.count
    }

    func knownCount(pinnedTo account: AccountID) -> Int { sessions.values.filter { $0.pins.values.contains(account) }.count }

    func records(now: Date = Date()) -> [SessionRecord] {
        sessions.map { id, s in
            SessionRecord(id: id, active: isActive(s, now: now), inFlight: s.inFlight, requests: s.requests, firstSeen: s.firstSeen,
                          lastSeen: s.lastSeen, client: s.client, pins: s.pins, starved: s.starved)
        }.sorted { $0.lastSeen > $1.lastSeen }
    }
}
