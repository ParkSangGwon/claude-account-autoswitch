import Foundation
@testable import AutoSwitchCore

/// Builders for the typed state the views and rules consume.
enum Fixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func id(_ label: String) -> AccountID { AccountID(rawValue: "id-\(label)") }

    static func account(_ label: String, rank: Int = 0, enabled: Bool = true, plan: Plan = .max(multiplier: 20), kind: CredentialKind = .subscription,
                        session: Double? = nil, sessionReset: TimeInterval? = 3600, weekly: Double? = nil, weeklyReset: TimeInterval? = 86_400 * 3,
                        fable: Double? = nil, sonnet: Double? = nil, blocker: Blocker? = nil, health: Health = .ok, coolingUntil: Date? = nil,
                        sessions: Int = 0, known: Int = 0, requests: Int = 0, probeError: String? = nil, overage: Overage? = nil,
                        tokens: Meter? = nil, requestsMeter: Meter? = nil) -> AccountStatus {
        var w = Windows()
        if let session { w[.session] = WindowReading(used: session, resetsAt: sessionReset.map { now.addingTimeInterval($0) }, seenAt: now) }
        if let weekly { w[.weekly] = WindowReading(used: weekly, resetsAt: weeklyReset.map { now.addingTimeInterval($0) }, seenAt: now) }
        if let fable { w[.weeklyFable] = WindowReading(used: fable, resetsAt: weeklyReset.map { now.addingTimeInterval($0) }, seenAt: now) }
        if let sonnet { w[.weeklySonnet] = WindowReading(used: sonnet, resetsAt: weeklyReset.map { now.addingTimeInterval($0) }, seenAt: now) }
        w.tokens = tokens; w.requests = requestsMeter
        var traffic = Traffic(); traffic.requests = requests
        return AccountStatus(id: id(label), label: label, kind: kind, plan: plan, rank: rank, enabled: enabled, organization: Organization(name: "Example Org", id: "org-1"),
                             claudeAccountID: nil, windows: w, health: health, coolingUntil: coolingUntil, blocker: blocker, activeSessions: sessions,
                             knownSessions: known, traffic: traffic, probe: probeError.map { ProbeResult(at: now, error: $0) }, overage: overage)
    }

    static func state(_ accounts: [AccountStatus], current: String? = nil, next: String? = nil, sessions: [SessionRecord] = [],
                      rotation: Configuration.Rotation = Configuration.Rotation(), running: Bool = true) -> EngineState {
        let cur = current.map(id) ?? accounts.first { $0.blocker == nil }?.id
        let nxt = next.map(id) ?? cur
        var targets: [Family: AccountID?] = [:]
        for f in Family.allCases where accounts.contains(where: { $0.windows[f.window] != nil }) { targets[f] = nxt }
        return EngineState(accounts: accounts, current: cur, next: nxt, familyTargets: targets, sessions: sessions, rotation: rotation,
                           listener: ListenerInfo(port: 10912, baseURL: "https://api.anthropic.com", startedAt: running ? now.addingTimeInterval(-600) : nil, version: "t"),
                           probe: ProbeInfo(enabled: true, intervalSeconds: 300, lastFinishedAt: now.addingTimeInterval(-60)), observedAt: now)
    }

    static func session(_ id: String, active: Bool = true, starved: Int = 0, client: String? = "claude-code", pins: [WindowKind: AccountID] = [:]) -> SessionRecord {
        SessionRecord(id: id, active: active, inFlight: 0, requests: 3, firstSeen: now.addingTimeInterval(-300), lastSeen: now, client: client, pins: pins, starved: starved)
    }
}
