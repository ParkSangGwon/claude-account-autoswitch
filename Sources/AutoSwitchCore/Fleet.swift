import Foundation

/// The fleet's position on one window: every enabled account's usage, weighted by what its plan is worth.
public struct FleetTotal: Sendable, Equatable {
    public var used: Double
    public var capacity: Double
    public var knownAccounts: Int
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
    public static func total(_ state: EngineState, _ kind: WindowKind) -> FleetTotal? {
        var capacity = 0.0, used = 0.0, known = 0
        var reset: Date?
        for a in state.accounts where a.enabled {
            guard let w = a.plan.weight, let r = a.windows[kind] else { continue }
            capacity += Double(w); used += Double(w) * r.used; known += 1
            if let at = r.resetsAt, reset.map({ at < $0 }) ?? true { reset = at }
        }
        guard capacity > 0 else { return nil }
        return FleetTotal(used: used / capacity, capacity: capacity, knownAccounts: known, nextResetAt: reset)
    }

    /// Accounts whose plan the fleet total cannot weigh.
    public static func unweighed(_ state: EngineState) -> [AccountStatus] {
        state.accounts.filter { $0.enabled && $0.plan.weight == nil }
    }

    /// The fleet's elapsed share of a window: each known account's, weighted the same way.
    public static func elapsedShare(_ state: EngineState, _ kind: WindowKind, now: Date = Date()) -> Double? {
        var weightSum = 0.0, acc = 0.0
        for a in state.accounts where a.enabled {
            guard let w = a.plan.weight, w > 0, let e = a.windows[kind]?.elapsedShare(length: kind.length, now: now) else { continue }
            weightSum += Double(w); acc += Double(w) * e
        }
        return weightSum > 0 ? acc / weightSum : nil
    }

    /// Every account's coming window resets, soonest first, so the return of capacity is visible.
    public static func resetTimeline(_ state: EngineState, now: Date = Date(), limit: Int = 6) -> [ResetEntry] {
        var out: [ResetEntry] = []
        for a in state.accounts {
            let frees = a.blocker != nil && a.blocker != .switchedOff
            for kind in WindowKind.allCases {
                guard let r = a.windows[kind], let at = r.resetsAt, at > now else { continue }
                // A family window that rolls over with the shared week says nothing new.
                if kind.family != nil, let shared = a.windows[.weekly]?.resetsAt, shared == at { continue }
                out.append(ResetEntry(account: a.id, label: a.label, kind: kind, resetsAt: at, freesCapacity: frees))
            }
        }
        return Array(out.sorted { $0.resetsAt != $1.resetsAt ? $0.resetsAt < $1.resetsAt : $0.label < $1.label }.prefix(limit))
    }
}
