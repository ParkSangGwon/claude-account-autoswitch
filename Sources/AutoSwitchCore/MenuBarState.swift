import Foundation

public enum IconState: Sendable, Equatable {
    case normal, warning, critical
    case rotating(to: String)
    case proxyDown, noAccounts, stale
    /// No answer yet and no failure either: the first poll is in flight.
    case starting
}

public struct IconInputs: Sendable {
    public var state: EngineState?
    public var reachable: Bool
    public var lastSuccessAt: Date?
    public var now: Date
    public var pollInterval: TimeInterval
    public var rotatedAt: Date?
    public var rotatedTo: String?
    public var pinCurrent: Bool
    public var showRemaining: Bool

    public init(state: EngineState?, reachable: Bool, lastSuccessAt: Date?, now: Date = Date(),
                pollInterval: TimeInterval = 30, rotatedAt: Date? = nil, rotatedTo: String? = nil,
                pinCurrent: Bool = false, showRemaining: Bool = false) {
        self.state = state; self.reachable = reachable; self.lastSuccessAt = lastSuccessAt; self.now = now
        self.pollInterval = pollInterval; self.rotatedAt = rotatedAt; self.rotatedTo = rotatedTo
        self.pinCurrent = pinCurrent; self.showRemaining = showRemaining
    }
}

/// What the status item draws. `Equatable` so the image is only re-rendered on change.
public struct IconModel: Sendable, Equatable {
    public var state: IconState
    /// Bar fills (0–1), already flipped to "remaining" when the preference says so.
    public var fiveHour: Double?
    public var weekly: Double?
    /// `1h12m 42%`: the countdown to the 5-hour reset, then the percentage.
    public var label: String?
    /// The weekly window in the same shape, for the style that shows both.
    public var weeklyLabel: String?
    public var tooltip: String
    /// Three-letter tag drawn under the bars when pinned to the current account.
    public var tag: String?
}

public enum MenuBarState {
    public static let rotatingFlashSeconds: TimeInterval = 6

    public static func compute(_ i: IconInputs) -> IconModel {
        let staleAfter = max(3 * i.pollInterval, 90)
        let age = i.lastSuccessAt.map { i.now.timeIntervalSince($0) }

        if !i.reachable, age == nil || age! > 10 {
            return IconModel(state: .proxyDown, fiveHour: nil, weekly: nil, label: "—", weeklyLabel: nil,
                             tooltip: L("the proxy not reachable") + (age.map { " · " + L("last data %@ ago", Format.duration($0)) } ?? ""), tag: nil)
        }
        guard let st = i.state else {
            return IconModel(state: .starting, fiveHour: nil, weekly: nil, label: nil, weeklyLabel: nil, tooltip: L("Claude AutoSwitch: connecting to the proxy…"), tag: nil)
        }
        if st.accounts.isEmpty {
            return IconModel(state: .noAccounts, fiveHour: 0, weekly: 0, label: "0%", weeklyLabel: nil, tooltip: L("No accounts configured — open Settings → Accounts"), tag: nil)
        }

        // Source of the bars: the fleet total by default, the current account when pinned.
        let current = st.currentAccount
        var fiveHour: Double?, weekly: Double?
        var fiveReset: Date?, weekReset: Date?
        var tag: String?
        if i.pinCurrent, let cur = current {
            fiveHour = cur.windows[.session]?.used; fiveReset = cur.windows[.session]?.resetsAt
            weekly = cur.windows[.weekly]?.used; weekReset = cur.windows[.weekly]?.resetsAt
            tag = Format.tag(cur.label)
        } else {
            let five = Fleet.total(st, .session), week = Fleet.total(st, .weekly)
            fiveHour = five?.used; fiveReset = five?.nextResetAt
            weekly = week?.used; weekReset = week?.nextResetAt
        }

        // Severity from the same pace rule the bars use, so the icon and the popover never disagree;
        // critical is the fleet's inability to serve or a bar at its threshold.
        let hold = st.isExhausted
        let fiveThreshold = st.rotation.switchAt(.session), weekThreshold = st.rotation.switchAt(.weekly)
        let fiveSeverity = fiveHour.map { Pace.severity(used: $0, resetsAt: fiveReset, length: WindowKind.session.length, threshold: fiveThreshold, now: i.now) }
        let weekSeverity = weekly.map { Pace.severity(used: $0, resetsAt: weekReset, length: WindowKind.weekly.length, threshold: weekThreshold, now: i.now) }
        let worst = [fiveSeverity, weekSeverity].compactMap { $0 }.max() ?? .calm
        let atThreshold = (fiveHour ?? 0) >= fiveThreshold - 0.05 || (weekly ?? 0) >= weekThreshold - 0.05
        // A blocked current account is only an emergency while nothing else can take the traffic.
        let stuck = current?.blocker != nil && !st.currentMovedOn
        let state: IconState
        if let age, age > staleAfter {
            state = .stale
        } else if let at = i.rotatedAt, let to = i.rotatedTo, i.now.timeIntervalSince(at) < rotatingFlashSeconds {
            state = .rotating(to: to)
        } else if hold || stuck || atThreshold {
            state = .critical
        } else if worst == .hot || worst == .critical {
            state = .warning
        } else {
            state = .normal
        }

        var label: String? = fiveHour.map { windowLabel(used: $0, resetsAt: fiveReset, now: i.now, remaining: i.showRemaining) }
        let weeklyLabel = weekly.map { windowLabel(used: $0, resetsAt: weekReset, now: i.now, remaining: i.showRemaining) }
        if case .rotating(let to) = state { label = "→ \(Format.tag(to))" }
        if state == .critical, let l = label, !l.hasSuffix("!") { label = l + "!" }

        var parts: [String] = ["Claude AutoSwitch"]
        if let cur = current { parts.append(L("current %@", cur.label)) }
        if let f = fiveHour { parts.append("5h \(Format.percentInt(f))%") }
        if let w = weekly { parts.append("7d \(Format.percentInt(w))%") }
        if let cur = current, let fable = cur.windows[.weeklyFable]?.used { parts.append("Fable \(Format.percentInt(fable))%") }
        if let cur = current, let reset = cur.windows[.session]?.resetsAt {
            let r = Format.countdown(reset, now: i.now)
            if !r.isEmpty { parts.append(L("5h resets in %@", r)) }
        }
        let available = st.accounts.filter { $0.blocker == nil }.count
        parts.append(L("%d/%d accounts available", available, st.accounts.count))
        var tooltip = parts.joined(separator: " · ")
        switch state {
        case .critical: tooltip = (hold ? L("Critical: every account is out of rotation") : stuck ? L("Critical: the current account cannot serve and nothing else can take over") : L("Critical: at the switch threshold")) + " · " + tooltip
        case .warning: tooltip = L("Warning") + " · " + tooltip
        case .stale: tooltip = L("Data is %@ old — the proxy answered slowly or not at all", Format.duration(age ?? 0)) + " · " + tooltip
        case .rotating(let to): tooltip = L("Rotated to %@", to) + " · " + tooltip
        default: break
        }

        return IconModel(state: state,
                         fiveHour: fiveHour.map { i.showRemaining ? 1 - $0 : $0 },
                         weekly: weekly.map { i.showRemaining ? 1 - $0 : $0 },
                         label: label, weeklyLabel: weeklyLabel, tooltip: tooltip, tag: tag)
    }

    /// `1h12m 42%`: the countdown to the window's reset, then the percentage; just the percentage when no reset is known.
    public static func windowLabel(used: Double, resetsAt: Date?, now: Date, remaining: Bool) -> String {
        let pct = "\(Format.percentInt(remaining ? 1 - used : used))%"
        let reset = Format.countdown(resetsAt, now: now)
        return reset.isEmpty ? pct : "\(reset) \(pct)"
    }
}
