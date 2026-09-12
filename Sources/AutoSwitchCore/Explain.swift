import Foundation

/// Something wrong that needs a person, worst first. Ordinary rotation never appears here.
public struct Notice: Sendable, Equatable {
    public enum Severity: Sendable { case bad, warn }
    public var severity: Severity
    public var kind: String
    public var text: String
}

/// Where the next request lands and why.
public struct NextRequest: Sendable, Equatable {
    public var account: AccountID
    public var label: String
    public var reason: String
    public var isCurrent: Bool
}

/// One line of the targets card: which account serves a family, and who else could.
public struct TargetRow: Sendable, Equatable, Identifiable {
    public var id: String { family?.rawValue ?? "default" }
    /// Nil for the row that covers every other model.
    public var family: Family?
    public var target: AccountID?
    public var eligible: [String]
    public var ineligible: [String]
    public var isCurrent: Bool
    public var currentBlocker: Blocker?

    public var title: String { family?.title ?? L("Everything else") }
}

/// What a manual switch did: recorded and taking effect are two different things.
public struct SwitchOutcome: Sendable, Equatable {
    public enum Kind: Sendable { case ok, warn, error }
    public var kind: Kind
    public var text: String

    public init(kind: Kind, text: String) { self.kind = kind; self.text = text }

    public static func switched(to label: String, blocker: Blocker?) -> SwitchOutcome {
        guard let blocker else { return SwitchOutcome(kind: .ok, text: L("switched to %@", label)) }
        return SwitchOutcome(kind: .warn, text: L("switched to %@, but rotation will not use it", label) + ": " + blocker.text)
    }

    public static func failed(_ why: String) -> SwitchOutcome { SwitchOutcome(kind: .error, text: L("switch failed") + ": " + why) }
}

/// Words for what the engine decided.
public enum Explain {
    public static let starvedMin = 5
    public static let starvedListMax = 3

    /// Why rotation left `from` for `to`: the old account's blocker, a better rank, or nothing we can name.
    public static func switchCause(from: AccountID, to: AccountID, state: EngineState, previous: EngineState? = nil) -> SwitchCause? {
        let old = state.account(from) ?? previous?.account(from)
        let new = state.account(to)
        if let b = old?.blocker { return .blocked(b) }
        if let o = old, let n = new, n.rank < o.rank { return .outranked(newRank: n.rank, oldRank: o.rank) }
        return nil
    }

    public static func nextRequest(_ state: EngineState, now: Date = Date()) -> NextRequest? {
        guard let id = state.next, let acc = state.account(id) else { return nil }
        var parts: [String] = []
        if let cur = state.current, cur != id, let cause = switchCause(from: cur, to: id, state: state) {
            parts.append(cause.text(from: state.label(cur) ?? "", to: acc.label, at: now))
        }
        parts.append(L("prio %d", acc.rank))
        if acc.activeSessions > 0 { parts.append(L("%d sess", acc.activeSessions)) }
        return NextRequest(account: id, label: acc.label, reason: parts.joined(separator: " · "), isCurrent: id == state.current)
    }

    /// The targets card: one row per family the fleet meters separately, then the row for everything else.
    public static func targets(_ state: EngineState) -> [TargetRow] {
        let families = Family.allCases.filter { f in state.accounts.contains { $0.windows[f.window] != nil } }
        guard !families.isEmpty else { return [] }
        var rows: [TargetRow] = families.map { f in
            let target = state.familyTargets[f] ?? nil
            let can = state.accounts.filter { a in a.blocker == nil && !(a.windows[f.window].map { $0.used >= state.rotation.switchAt(f.window) } ?? false) }
            let cannot = state.accounts.filter { a in !can.contains { $0.id == a.id } }
            return TargetRow(family: f, target: target, eligible: can.map(\.label), ineligible: cannot.map(\.label), isCurrent: target == state.current, currentBlocker: nil)
        }
        rows.append(TargetRow(family: nil, target: state.next, eligible: [], ineligible: [], isCurrent: state.next == state.current, currentBlocker: state.currentAccount?.blocker))
        return rows
    }

    public static func notices(_ state: EngineState) -> [Notice] {
        var out: [Notice] = []
        let stalled = state.accounts.filter { a in
            if case .windowFull = a.blocker { return true }
            if case .coolingDown = a.blocker { return true }
            return false
        }
        let why: String
        if !state.accounts.isEmpty, stalled.count == state.accounts.count {
            let full = stalled.contains { if case .windowFull = $0.blocker { return true } else { return false } }
            let cooling = stalled.contains { if case .coolingDown = $0.blocker { return true } else { return false } }
            let cause = full && cooling ? L("over its quota threshold or in a rate-limit hold") : full ? L("over its quota threshold") : L("in a rate-limit hold")
            why = " — " + L("every account is %@.", cause)
        } else {
            why = " — " + L("it is failing, not idle.")
        }
        let starving = state.sessions.filter { $0.active && $0.starved >= starvedMin }.sorted { $0.starved > $1.starved }
        for s in starving.prefix(starvedListMax) {
            let head = s.client.map { L("Session %@", Text.safe($0, max: 32)) } ?? L("Session")
            out.append(Notice(severity: .bad, kind: "starved-session",
                              text: L("%@ %@ has had %d requests in a row come back with nothing", head, String(s.id.prefix(8)), s.starved) + why))
        }
        if starving.count > starvedListMax {
            out.append(Notice(severity: .bad, kind: "starved-more", text: L("and %d more sessions are getting nothing back.", starving.count - starvedListMax)))
        }
        for a in state.accounts {
            if a.blocker == .needsLogin { out.append(Notice(severity: .warn, kind: "account", text: L("Account %@ needs a re-login.", a.label))) }
            if a.blocker == .switchedOff { out.append(Notice(severity: .warn, kind: "account", text: L("Account %@ is disabled.", a.label))) }
        }
        return out
    }

    /// Why nothing can serve, for the banner and the notification.
    public static func exhaustedReason(_ state: EngineState) -> String {
        let stalled = state.accounts.filter { a in
            if case .windowFull = a.blocker { return true }
            if case .coolingDown = a.blocker { return true }
            return false
        }
        return stalled.count == state.accounts.count ? L("every account is over its quota threshold or in a rate-limit hold") : L("every account is out of rotation")
    }

    /// Display aliases that stay unique: the local part of an e-mail, then the organization, then a number.
    public static func aliases(for accounts: [(label: String, org: String?)]) -> [String: String] {
        func base(_ s: String) -> String { String(s.split(separator: "@").first ?? Substring(s)) }
        var groups: [String: [(String, String?)]] = [:]
        var order: [String] = []
        for a in accounts {
            let b = base(a.label)
            if groups[b] == nil { order.append(b) }
            groups[b, default: []].append((a.label, a.org))
        }
        var out: [String: String] = [:]
        for b in order {
            let members = groups[b] ?? []
            if members.count == 1 { out[members[0].0] = b; continue }
            let orgs = members.map { $0.1 ?? "" }
            let orgsUnique = Set(orgs).count == members.count && !orgs.contains("")
            for (i, m) in members.enumerated() {
                out[m.0] = orgsUnique ? "\(b) (\(m.1 ?? ""))" : (i == 0 ? b : "\(b) \(i + 1)")
            }
        }
        return out
    }
}

/// Strings off the wire started life in an OAuth reply or a config file: drop control
/// characters and cap the length before they reach a menu or a notification.
public enum Text {
    public static func safe(_ s: String) -> String { safe(s, max: 512) }

    public static func safe(_ s: String, max: Int) -> String {
        var out = ""
        for u in s.unicodeScalars where !(u.value < 0x20 || u.value == 0x7f || (u.value >= 0x80 && u.value < 0xa0)) {
            out.unicodeScalars.append(u)
        }
        if out.count > max { return String(out.prefix(max - 1)) + "…" }
        return out
    }
}
