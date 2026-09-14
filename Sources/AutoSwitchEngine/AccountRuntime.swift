import Foundation
import AutoSwitchCore

/// One account as the engine runs it: the record plus everything learned since start-up.
/// Tokens stay in the record and the config file; nothing else reads them.
struct AccountRuntime: Sendable {
    /// How many 429s in a row the upstream declines to pin on a window before the account waits.
    static let unattributedRefusalsBeforeCoolDown = 3

    var record: AccountRecord
    var windows = Windows()
    var health: Health = .ok
    var coolingUntil: Date?
    /// 429s in a row that named no window; reset by the next reply this account serves.
    var unattributedRefusals = 0
    var traffic = Traffic()
    var probe: ProbeResult?
    var overage: Overage?

    init(record: AccountRecord) { self.record = record }

    var id: AccountID { record.id }
    var label: String { record.label }

    /// The same account survived a config reload: keep what was learned.
    mutating func inherit(from old: AccountRuntime) {
        windows = old.windows; health = old.health; coolingUntil = old.coolingUntil
        unattributedRefusals = old.unattributedRefusals
        traffic = old.traffic; probe = old.probe; overage = old.overage
    }

    /// What goes on the wire: the bearer token or the API key.
    var secret: String? {
        switch record.credential {
        case .oauth(let t): return t.access
        case .apiKey(let k): return k
        }
    }

    var oauthTokens: OAuthTokens? {
        if case .oauth(let t) = record.credential { return t }
        return nil
    }

    mutating func coolDown(seconds: Double, now: Date = Date()) {
        health = .coolingDown
        coolingUntil = now.addingTimeInterval(seconds)
    }

    /// A 429 the upstream would not attribute to any window. One is not this account's fault —
    /// a burst, a busy upstream, something a sibling would hit too — so it only steps aside for
    /// this request. Repeats are the account's own problem and earn a real cool-down.
    mutating func noteUnattributedRefusal(retryAfter: Double, now: Date = Date()) {
        unattributedRefusals += 1
        guard unattributedRefusals >= AccountRuntime.unattributedRefusalsBeforeCoolDown else { return }
        coolDown(seconds: min(max(retryAfter, 1), 60), now: now)
    }

    mutating func warmUp() {
        unattributedRefusals = 0
        if health == .coolingDown { health = .ok; coolingUntil = nil }
    }

    /// Cool-downs and windows that have run out are forgotten.
    mutating func sweep(now: Date) {
        windows.sweep(now: now)
        // The wait is over: the account comes back with a clean slate, or three old refusals would
        // send it straight back into a cool-down on its first request.
        if health == .coolingDown, let until = coolingUntil, until <= now {
            health = .ok; coolingUntil = nil; unattributedRefusals = 0
        }
    }

    func status(blocker: Blocker?, activeSessions: Int, knownSessions: Int) -> AccountStatus {
        AccountStatus(id: id, label: label, kind: record.kind, plan: record.plan, rank: record.rank, enabled: record.enabled,
                      organization: record.organization, claudeAccountID: record.claudeAccountID, windows: windows, health: health,
                      coolingUntil: coolingUntil, blocker: blocker, activeSessions: activeSessions, knownSessions: knownSessions,
                      traffic: traffic, probe: probe, overage: overage)
    }
}
