import Foundation

/// The quota windows Claude meters a subscription on: one rolling five-hour window, one rolling
/// week, and a separate week for each model family that is metered on its own.
public enum WindowKind: String, Codable, Sendable, CaseIterable, Hashable {
    case session
    case weekly
    case weeklyFable
    case weeklySonnet

    public var length: TimeInterval { self == .session ? 5 * 3600 : 7 * 24 * 3600 }

    /// The family a window meters, when it is not shared.
    public var family: Family? {
        switch self {
        case .weeklyFable: return .fable
        case .weeklySonnet: return .sonnet
        default: return nil
        }
    }

    /// `5h`, `wk`, `F7`, `S7`: the two- or three-character tag the reset timeline and the tooltip use.
    public var tag: String {
        switch self {
        case .session: return "5h"
        case .weekly: return L("wk")
        case .weeklyFable: return "F7"
        case .weeklySonnet: return "S7"
        }
    }

    public var title: String {
        switch self {
        case .session: return L("Session")
        case .weekly: return L("Weekly")
        case .weeklyFable: return "Fable"
        case .weeklySonnet: return "Sonnet"
        }
    }

    /// The weekly window a request draws on: the family's own when it has one, the shared week otherwise.
    public static func weekly(for model: String?) -> WindowKind {
        Family.of(model: model)?.window ?? .weekly
    }
}

/// Model families with a weekly window of their own.
public enum Family: String, Codable, Sendable, CaseIterable, Hashable {
    case fable
    case sonnet

    public var window: WindowKind { self == .fable ? .weeklyFable : .weeklySonnet }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    public static func of(model: String?) -> Family? {
        let m = (model ?? "").lowercased()
        return allCases.first { m.contains($0.rawValue) }
    }
}

/// What is known about one window: how much of it is used and when it rolls over.
public struct WindowReading: Codable, Sendable, Equatable {
    /// 0…1.
    public var used: Double
    public var resetsAt: Date?
    public var seenAt: Date?

    public init(used: Double, resetsAt: Date?, seenAt: Date? = nil) {
        self.used = used; self.resetsAt = resetsAt; self.seenAt = seenAt
    }

    /// Fraction of the window already elapsed (the tick on a bar); nil when the reset is unknown.
    public func elapsedShare(length: TimeInterval, now: Date) -> Double? {
        guard let resetsAt else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return 1 }
        guard remaining <= length else { return nil }
        return (length - remaining) / length
    }
}

/// A counted allowance (tokens or requests) an API key has per window.
public struct Meter: Codable, Sendable, Equatable {
    public var limit: Double
    public var remaining: Double

    public init(limit: Double, remaining: Double) { self.limit = limit; self.remaining = remaining }

    public var used: Double? {
        guard limit > 0, limit.isFinite, remaining.isFinite else { return nil }
        return 1 - remaining / limit
    }
}

/// Everything the upstream has told us about an account's allowances.
public struct Windows: Codable, Sendable, Equatable {
    public var readings: [WindowKind: WindowReading] = [:]
    public var tokens: Meter?
    public var requests: Meter?
    public var metersResetAt: Date?
    /// The upstream flagged the account's unified status as rejected; forgotten after half an hour.
    public var refusedAt: Date?

    public init() {}

    public subscript(kind: WindowKind) -> WindowReading? {
        get { readings[kind] }
        set { readings[kind] = newValue }
    }

    public var isEmpty: Bool { readings.isEmpty && tokens == nil && requests == nil }

    public var isRefused: Bool { refusedAt != nil }

    /// Forget every window whose reset has passed, so a stale number never keeps an account out.
    public mutating func sweep(now: Date) {
        for (kind, r) in readings where r.resetsAt.map({ $0 <= now }) ?? false { readings.removeValue(forKey: kind) }
        if readings[.session] == nil { refusedAt = nil }
        if let at = refusedAt, now.timeIntervalSince(at) > 1800 { refusedAt = nil }
        if let at = metersResetAt, at <= now { tokens = nil; requests = nil; metersResetAt = nil }
    }
}
