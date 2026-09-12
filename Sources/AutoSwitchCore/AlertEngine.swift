import Foundation

/// What the app should notify about. `id` doubles as the dedupe key: the
/// notification centre replaces a pending notification with the same id.
public struct Alert: Sendable, Equatable {
    public enum Kind: String, Sendable { case fleetLevel, rotation, accountError, hold, proxyDown, proxyBack, spend, accountLeft, accountBack, probeFailed }
    public var kind: Kind
    public var id: String
    public var title: String
    public var body: String
    public var sound: Bool
}

public struct AlertPrefs: Sendable, Equatable, Codable {
    public var levels: [Int] = [90, 95]
    public var fleetFiveHour = true
    public var fleetWeekly = true
    public var rotation = true
    public var accountError = true
    public var hold = true
    public var proxyDown = true
    public var proxyBack = false
    public var spend = true
    /// An account dropping out of rotation (threshold, 429 hold, cap); off by default, it is routine.
    public var accountLeft = false
    /// An account's window reset (or hold cleared) bringing it back.
    public var accountBack = false
    /// The quota probe failing for an account, once per failure streak.
    public var probeFailed = true
    public var pausedUntil: Date? = nil

    public init() {}

    /// A blob written by an older build lacks the keys added since; they take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        levels = try c.decodeIfPresent([Int].self, forKey: .levels) ?? levels
        fleetFiveHour = try c.decodeIfPresent(Bool.self, forKey: .fleetFiveHour) ?? fleetFiveHour
        fleetWeekly = try c.decodeIfPresent(Bool.self, forKey: .fleetWeekly) ?? fleetWeekly
        rotation = try c.decodeIfPresent(Bool.self, forKey: .rotation) ?? rotation
        accountError = try c.decodeIfPresent(Bool.self, forKey: .accountError) ?? accountError
        hold = try c.decodeIfPresent(Bool.self, forKey: .hold) ?? hold
        proxyDown = try c.decodeIfPresent(Bool.self, forKey: .proxyDown) ?? proxyDown
        proxyBack = try c.decodeIfPresent(Bool.self, forKey: .proxyBack) ?? proxyBack
        spend = try c.decodeIfPresent(Bool.self, forKey: .spend) ?? spend
        accountLeft = try c.decodeIfPresent(Bool.self, forKey: .accountLeft) ?? accountLeft
        accountBack = try c.decodeIfPresent(Bool.self, forKey: .accountBack) ?? accountBack
        probeFailed = try c.decodeIfPresent(Bool.self, forKey: .probeFailed) ?? probeFailed
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
    }

    public func isPaused(at now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }
}

/// Persisted between launches so a relaunch does not re-fire a level already announced.
public struct AlertState: Sendable, Equatable, Codable {
    public var seeded = false
    /// metric → levels already fired; a level re-arms once usage falls five points below it.
    public var fired: [String: [Int]] = [:]
    /// The account (id) unrouted requests landed on at the last evaluation.
    public var lastNext: String? = nil
    public var allOut = false
    public var loginNeeded: [String] = []
    public var downStreak = 0
    public var announcedDown = false
    public var spendSeen: [String] = []
    /// account id → its blocker code at the last evaluation (absent = in rotation).
    public var blockedByAccount: [String: String] = [:]
    public var probeErrorAccounts: [String] = []

    public init() {}

    /// Missing keys (a blob from before they existed) must not throw the whole state
    /// away, or every already-announced level fires again after an update.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? seeded
        fired = try c.decodeIfPresent([String: [Int]].self, forKey: .fired) ?? fired
        lastNext = try c.decodeIfPresent(String.self, forKey: .lastNext)
        allOut = try c.decodeIfPresent(Bool.self, forKey: .allOut) ?? allOut
        loginNeeded = try c.decodeIfPresent([String].self, forKey: .loginNeeded) ?? loginNeeded
        downStreak = try c.decodeIfPresent(Int.self, forKey: .downStreak) ?? downStreak
        announcedDown = try c.decodeIfPresent(Bool.self, forKey: .announcedDown) ?? announcedDown
        spendSeen = try c.decodeIfPresent([String].self, forKey: .spendSeen) ?? spendSeen
        blockedByAccount = try c.decodeIfPresent([String: String].self, forKey: .blockedByAccount) ?? blockedByAccount
        probeErrorAccounts = try c.decodeIfPresent([String].self, forKey: .probeErrorAccounts) ?? probeErrorAccounts
    }
}

public struct AlertInputs: Sendable {
    public var previous: EngineState?
    public var state: EngineState?
    public var reachable: Bool
    /// The account the app itself just switched to (suppresses the rotation alert for it).
    public var appSwitchedTo: AccountID?
    public var now: Date

    public init(previous: EngineState?, state: EngineState?, reachable: Bool, appSwitchedTo: AccountID? = nil, now: Date = Date()) {
        self.previous = previous; self.state = state; self.reachable = reachable; self.appSwitchedTo = appSwitchedTo; self.now = now
    }
}

public enum AlertEngine {
    public static let downStreakToAnnounce = 2
    /// A level re-arms once utilization drops this many points below it.
    public static let hysteresisPoints = 5

    public static func evaluate(_ inputs: AlertInputs, state: AlertState, prefs: AlertPrefs) -> (alerts: [Alert], state: AlertState) {
        var s = state
        var out: [Alert] = []
        let paused = prefs.isPaused(at: inputs.now)
        // Hold and proxy-down stay audible while paused; everything else is muted.
        func emit(_ a: Alert) {
            if paused && a.kind != .hold && a.kind != .proxyDown { return }
            out.append(a)
        }

        // Reachability first: it does not need a state.
        if inputs.reachable {
            if s.announcedDown {
                if prefs.proxyBack { emit(Alert(kind: .proxyBack, id: "proxy.back", title: L("the proxy is back"), body: L("Status is updating again."), sound: false)) }
                s.announcedDown = false
            }
            s.downStreak = 0
        } else {
            s.downStreak += 1
            if s.downStreak >= downStreakToAnnounce, !s.announcedDown {
                s.announcedDown = true
                if prefs.proxyDown { emit(Alert(kind: .proxyDown, id: "proxy.down", title: L("the proxy is not responding"), body: L("No answer from the proxy. Open the log or restart the service."), sound: true)) }
            }
        }

        guard let st = inputs.state else { return (out, s) }
        let seeding = !s.seeded
        s.seeded = true

        // Fleet levels (5h / weekly): once per crossing, re-armed by the hysteresis band only.
        let metrics: [(WindowKind, String, Bool, String)] = [
            (.session, "fleet.5h", prefs.fleetFiveHour, L("Fleet 5-hour usage")),
            (.weekly, "fleet.7d", prefs.fleetWeekly, L("Fleet weekly usage")),
        ]
        for (kind, key, enabled, title) in metrics {
            guard let total = Fleet.total(st, kind) else { continue }
            var fired = s.fired[key] ?? []
            let pct = total.used * 100
            for level in prefs.levels.sorted() {
                if pct >= Double(level) {
                    if !fired.contains(level) {
                        fired.append(level)
                        if enabled, !seeding {
                            let reset = total.nextResetAt.map { " · " + L("next reset in %@", Format.countdown($0, now: inputs.now)) } ?? ""
                            // One id per metric and level: the next window's alert replaces the last instead of piling up.
                            emit(Alert(kind: .fleetLevel, id: "\(key).\(level)", title: L("%@ at %d%%", title, Format.percentInt(total.used)),
                                       body: L("%d accounts weighted by tier", total.knownAccounts) + reset, sound: false))
                        }
                    }
                } else if pct < Double(level - hysteresisPoints) {
                    fired.removeAll { $0 == level }
                }
            }
            s.fired[key] = fired
        }

        // Rotation: the account new requests land on changed.
        if let next = st.next {
            if let prevRaw = s.lastNext, prevRaw != next.rawValue, !seeding, next != inputs.appSwitchedTo, prefs.rotation {
                let prev = AccountID(rawValue: prevRaw)
                let from = st.label(prev) ?? inputs.previous?.label(prev) ?? prevRaw
                let to = st.label(next) ?? next.rawValue
                let reason = Explain.switchCause(from: prev, to: next, state: st, previous: inputs.previous)?.text(from: from, to: to, at: inputs.now)
                emit(Alert(kind: .rotation, id: "rotate.\(prevRaw).\(next.rawValue)", title: L("Rotated: %@ → %@", from, to),
                           body: reason ?? L("Rotation moved to %@.", to), sound: true))
            }
            s.lastNext = next.rawValue
        }

        // An account that needs a person.
        let needing = st.accounts.filter { $0.blocker == .needsLogin }
        for a in needing where !s.loginNeeded.contains(a.id.rawValue) && !seeding && prefs.accountError {
            emit(Alert(kind: .accountError, id: "acct.error.\(a.id.rawValue)", title: L("%@ needs a re-login", a.label), body: L("The account is in an error state. Open Settings → Accounts."), sound: false))
        }
        s.loginNeeded = needing.map(\.id.rawValue)

        // Per-account rotation transitions: out (threshold, 429 hold, cap) and back (window reset, hold cleared).
        var nowBlocked: [String: String] = [:]
        for a in st.accounts {
            let before = s.blockedByAccount[a.id.rawValue]
            if let b = a.blocker {
                nowBlocked[a.id.rawValue] = b.code
                if before == nil, !seeding, prefs.accountLeft, !b.needsPerson {
                    let reset = b.liftsAt.map { " · " + L("resets in %@", Format.countdown($0, now: inputs.now)) } ?? ""
                    emit(Alert(kind: .accountLeft, id: "acct.left.\(a.id.rawValue)", title: L("%@ left rotation", a.label), body: b.text(now: inputs.now) + reset, sound: false))
                }
            } else if let code = before, !seeding, prefs.accountBack, code != Blocker.switchedOff.code, code != Blocker.needsLogin.code {
                emit(Alert(kind: .accountBack, id: "acct.back.\(a.id.rawValue)", title: L("%@ is back in rotation", a.label),
                           body: code == "full" ? L("Its window reset.") : L("The hold cleared."), sound: false))
            }
        }
        s.blockedByAccount = nowBlocked

        // The quota probe failing for an account: its bars are going stale.
        let failing = st.accounts.filter { $0.probe?.error != nil }
        for a in failing where !s.probeErrorAccounts.contains(a.id.rawValue) && !seeding && prefs.probeFailed {
            emit(Alert(kind: .probeFailed, id: "probe.\(a.id.rawValue)", title: L("Quota probe failing for %@", a.label),
                       body: a.probe?.error ?? L("The probe returned an error; the account's bars stop updating until it recovers."), sound: false))
        }
        s.probeErrorAccounts = failing.map(\.id.rawValue)

        // Every account out of rotation.
        let hold = st.isExhausted
        if hold, !s.allOut, !seeding, prefs.hold {
            emit(Alert(kind: .hold, id: "hold", title: L("No account can serve requests"), body: Explain.exhaustedReason(st), sound: true))
        }
        s.allOut = hold

        // First billable overage seen this month, per account.
        let month = Calendar.current.dateComponents([.year, .month], from: inputs.now)
        let monthKey = "\(month.year ?? 0)-\(month.month ?? 0)"
        for a in st.accounts {
            guard let o = a.overage, o.enabled, let used = o.usedMinor, used > 0 else { continue }
            let key = "spend.\(a.id.rawValue).\(monthKey)"
            if !s.spendSeen.contains(key) {
                s.spendSeen.append(key)
                if !seeding, prefs.spend {
                    emit(Alert(kind: .spend, id: key, title: L("%@ is billing overage", a.label), body: L("%@ used this month", Format.money(minor: used, currency: o.currency, exponent: o.exponent)), sound: false))
                }
            }
        }
        if s.spendSeen.count > 64 { s.spendSeen.removeFirst(s.spendSeen.count - 64) }

        return (out, s)
    }
}
