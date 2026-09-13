import Foundation

/// The fleet's position on one window: every enabled account's usage, weighted by what its plan is worth.
public struct FleetTotal: Sendable, Equatable {
    public var used: Double
    public var capacity: Double
    /// Accounts with a weighable plan that report this window.
    public var knownAccounts: Int
    /// Of those, the ones whose allowance the fleet can still spend.
    public var countedAccounts: Int
    public var nextResetAt: Date?

    public var remaining: Double { 1 - used }
}

public struct ResetEntry: Sendable, Equatable, Identifiable {
    public var id: String { "\(account.rawValue)/\(kind.rawValue)" }
    public var account: AccountID
    public var label: String
    public var kind: WindowKind
    public var resetsAt: Date
    /// The account is out of rotation now, so this reset brings capacity back.
    public var freesCapacity: Bool
}

public enum Fleet {
    /// An account out of rotation for longer than this window lasts contributes nothing: the fresh
    /// five hours behind a spent week are capacity on paper only, and averaging them in hides how
    /// little the fleet can actually serve.
    public static func total(_ state: EngineState, _ kind: WindowKind) -> FleetTotal? {
        var capacity = 0.0, used = 0.0, known = 0, counted = 0
        var reset: Date?, relief: Date?
        for a in state.accounts where a.enabled {
            guard let w = a.plan.weight, let r = a.windows[kind] else { continue }
            known += 1
            guard a.canSpend(kind) else {
                if let at = a.blocker?.liftsAt, relief.map({ at < $0 }) ?? true { relief = at }
                continue
            }
            capacity += Double(w); used += Double(w) * r.used; counted += 1
            if let at = r.resetsAt, reset.map({ at < $0 }) ?? true { reset = at }
        }
        guard known > 0 else { return nil }
        // Nothing left that can spend this window: the fleet is out of it, whatever the stranded accounts read.
        guard capacity > 0 else { return FleetTotal(used: 1, capacity: 0, knownAccounts: known, countedAccounts: 0, nextResetAt: relief) }
        return FleetTotal(used: used / capacity, capacity: capacity, knownAccounts: known, countedAccounts: counted, nextResetAt: reset)
    }

    /// Accounts whose plan the fleet total cannot weigh.
    public static func unweighed(_ state: EngineState) -> [AccountStatus] {
        state.accounts.filter { $0.enabled && $0.plan.weight == nil }
    }

    /// Every account's coming window resets, soonest first, so the return of capacity is visible.
    public static func resetTimeline(_ state: EngineState, now: Date = Date(), limit: Int = 6) -> [ResetEntry] {
        var out: [ResetEntry] = []
        for a in state.accounts {
            for kind in WindowKind.allCases {
                guard let r = a.windows[kind], let at = r.resetsAt, at > now else { continue }
                // A family window that rolls over with the shared week says nothing new.
                if kind.family != nil, let shared = a.windows[.weekly]?.resetsAt, shared == at { continue }
                // Only the reset that lifts the blocker brings the account back: a five-hour
                // rollover on a weekly-capped account returns nothing.
                let frees = a.blocker.map { $0 != .switchedOff && ($0.window == kind || $0.liftsAt == at) } ?? false
                out.append(ResetEntry(account: a.id, label: a.label, kind: kind, resetsAt: at, freesCapacity: frees))
            }
        }
        return Array(out.sorted { $0.resetsAt != $1.resetsAt ? $0.resetsAt < $1.resetsAt : $0.label < $1.label }.prefix(limit))
    }
}
