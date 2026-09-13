import Foundation

/// What moved new requests from one account to another. Kept as data so an entry reads in
/// whichever language is active when it is shown.
public enum SwitchCause: Codable, Sendable, Equatable {
    /// The old account could not serve.
    case blocked(Blocker)
    /// A better-ranked account was available.
    case outranked(newRank: Int, oldRank: Int)
    /// Chosen from the app.
    case manual
    /// Spread across accounts for a new session.
    case spread
    /// Traffic moved on without a reason the engine could name (a pinned session, a reload).
    case moved

    public func text(from: String, to: String, at: Date) -> String {
        switch self {
        case .blocked(let b):
            var s = "\(from): \(b.text(now: at))"
            if case .windowFull(_, let resetsAt) = b, let resetsAt { s += " · " + L("resets in %@", Format.countdown(resetsAt, now: at)) }
            return s
        case .outranked(let n, let o): return L("%@ outranks %@ (priority %d < %d)", to, from, n, o)
        case .manual: return L("switched from the app")
        case .spread: return L("spread to %@ for a new session", to)
        case .moved: return L("rotation moved to %@", to)
        }
    }
}

public struct SwitchEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: Date { at }
    public var at: Date
    public var from: String?
    public var to: String
    public var cause: SwitchCause
    public var manual: Bool { cause == .manual }

    public init(at: Date, from: String?, to: String, cause: SwitchCause) {
        self.at = at; self.from = from; self.to = to; self.cause = cause
    }

    /// The reason as of the event, not of now: a countdown recorded then stays what it was.
    public var reasonText: String { cause.text(from: from ?? "—", to: to, at: at) }
}

/// The most recent switches, newest last. Fifty filled up in half a day on a busy account,
/// which put "why did it move last week" out of reach; these are small rows in a preference.
public struct Journal: Codable, Sendable, Equatable {
    public static let capacity = 500
    public var events: [SwitchEvent] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.decodeIfPresent([SwitchEvent].self, forKey: .events) ?? []
    }

    public mutating func append(_ e: SwitchEvent) {
        events.append(e)
        if events.count > Journal.capacity { events.removeFirst(events.count - Journal.capacity) }
    }

    public var latest: [SwitchEvent] { events.reversed() }

    public func count(within window: TimeInterval, now: Date = Date()) -> Int {
        events.filter { now.timeIntervalSince($0.at) <= window }.count
    }
}
