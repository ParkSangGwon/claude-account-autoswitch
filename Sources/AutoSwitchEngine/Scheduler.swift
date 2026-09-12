import Foundation
import AutoSwitchCore

/// Which account takes a request. Every rule lives here; the relay only asks.
extension Engine {
    func runtimeIndex(_ id: AccountID) -> Int? { runtime.firstIndex { $0.id == id } }

    /// Why an account cannot take a request now, checked in the order a person would want to hear it.
    func blocker(of r: AccountRuntime, model: String? = nil, now: Date) -> Blocker? {
        if !r.record.enabled { return .switchedOff }
        if let cap = r.record.cap {
            for kind in WindowKind.allCases {
                if let limit = cap.limit(for: kind), let used = r.windows[kind]?.used, used >= limit { return .capped(kind) }
            }
        }
        if r.health == .coolingDown, let until = r.coolingUntil, now < until { return .coolingDown(until: until) }
        if r.health == .drained { return .drained }
        if r.health == .needsLogin { return .needsLogin }
        let rotation = configuration.rotation
        for kind in [WindowKind.session, .weekly] {
            if let w = r.windows[kind], w.used >= rotation.switchAt(kind) { return .windowFull(kind, resetsAt: w.resetsAt) }
        }
        if let used = r.windows.tokens?.used ?? r.windows.requests?.used, used >= rotation.switchAt { return .meterFull(resetsAt: r.windows.metersResetAt) }
        // A family with its own weekly window can be spent while the shared one is not.
        if let family = Family.of(model: model), let w = r.windows[family.window], w.used >= rotation.switchAt(family.window) {
            return .windowFull(family.window, resetsAt: w.resetsAt)
        }
        if r.windows.isRefused { return .refused }
        return nil
    }

    func canServe(_ id: AccountID, model: String? = nil, now: Date) -> Bool {
        guard let r = runtime.first(where: { $0.id == id }) else { return false }
        return blocker(of: r, model: model, now: now) == nil
    }

    /// Lowest rank first, then the account whose weekly window resets soonest, then config order.
    func bestCandidate(model: String? = nil, excluding: Set<AccountID>, now: Date) -> AccountID? {
        runtime.indices.filter { !excluding.contains(runtime[$0].id) && blocker(of: runtime[$0], model: model, now: now) == nil }.min { i, j in
            let a = runtime[i], b = runtime[j]
            if a.record.rank != b.record.rank { return a.record.rank < b.record.rank }
            let ra = a.windows[.weekly]?.resetsAt ?? .distantFuture, rb = b.windows[.weekly]?.resetsAt ?? .distantFuture
            if ra != rb { return ra < rb }
            return i < j
        }.map { runtime[$0].id }
    }

    /// Spreading: among the best-ranked accounts that can serve, the one with the fewest active sessions.
    func leastLoaded(model: String?, excluding: Set<AccountID>, now: Date) -> AccountID? {
        let candidates = runtime.filter { !excluding.contains($0.id) && blocker(of: $0, model: model, now: now) == nil }
        guard let top = candidates.map(\.record.rank).min() else { return nil }
        return candidates.filter { $0.record.rank == top }.min { affinity.activeCount(pinnedTo: $0.id, now: now) < affinity.activeCount(pinnedTo: $1.id, now: now) }?.id
    }

    /// A session stays with its account while that account can serve and no better-ranked one exists;
    /// otherwise spreading, the cursor, or the best candidate, in that order.
    func choose(model: String?, session: String?, excluding: Set<AccountID>, now: Date) -> AccountID? {
        let window = WindowKind.weekly(for: model)
        func ok(_ id: AccountID) -> Bool { !excluding.contains(id) && canServe(id, model: model, now: now) }
        func rank(_ id: AccountID) -> Int { runtime.first { $0.id == id }?.record.rank ?? Int.max }
        if let pinned = affinity.pin(session, window: window) ?? affinity.anyPin(session), ok(pinned) {
            if let better = bestCandidate(model: model, excluding: excluding, now: now), rank(better) < rank(pinned) { return better }
            return pinned
        }
        if configuration.rotation.spreadSessions, session != nil, let least = leastLoaded(model: model, excluding: excluding, now: now) { return least }
        if let cur = cursor, ok(cur) {
            if let better = bestCandidate(model: model, excluding: excluding, now: now), rank(better) < rank(cur) { return better }
            return cur
        }
        return bestCandidate(model: model, excluding: excluding, now: now)
    }

    /// Where the next unrouted request lands: the cursor while it can serve and nothing outranks it, else the best candidate.
    func nextTarget(now: Date) -> AccountID? { choose(model: nil, session: nil, excluding: [], now: now) }

    /// How long until any account can serve again: the earliest cool-down or reset, or a minute.
    func earliestRelief(now: Date) -> Double {
        var dates: [Date] = []
        for r in runtime {
            if let until = r.coolingUntil { dates.append(until) }
            if let at = r.windows[.session]?.resetsAt { dates.append(at) }
            if let at = r.windows.metersResetAt { dates.append(at) }
        }
        guard let soonest = dates.filter({ $0 > now }).min() else { return 60 }
        return max(1, soonest.timeIntervalSince(now).rounded(.up))
    }

    func sweep(now: Date) {
        for i in runtime.indices { runtime[i].sweep(now: now) }
        affinity.expire(now: now)
    }
}
