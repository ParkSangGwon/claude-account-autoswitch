import Foundation

/// Why an account cannot take the next request. Checked in this order, so the first
/// blocker found is the one that matters most to a person reading it.
public enum Blocker: Codable, Sendable, Equatable, Hashable {
    /// Turned off in Settings.
    case switchedOff
    /// Its usage cap is reached on this window.
    case capped(WindowKind)
    /// A 429 asked for a pause; the account is back once `until` passes.
    case coolingDown(until: Date)
    /// The upstream said the account is spent for now.
    case drained
    /// The refresh token was rejected; only a new sign-in helps.
    case needsLogin
    /// This window is at the switch threshold.
    case windowFull(WindowKind, resetsAt: Date?)
    /// An API key's token or request allowance is at the switch threshold.
    case meterFull(resetsAt: Date?)
    /// The upstream flagged the account's window as rejected on its last reply.
    case refused

    /// Ordinary rotation (a window filling up, a cool-down) versus something a person must handle.
    public var needsPerson: Bool {
        switch self {
        case .switchedOff, .needsLogin: return true
        default: return false
        }
    }

    /// The reset that will lift the blocker on its own, when there is one.
    public var liftsAt: Date? {
        switch self {
        case .coolingDown(let until): return until
        case .windowFull(_, let resetsAt): return resetsAt
        case .meterFull(let resetsAt): return resetsAt
        default: return nil
        }
    }

    /// A short key for logs and history strips.
    public var code: String {
        switch self {
        case .switchedOff: return "off"
        case .capped: return "capped"
        case .coolingDown: return "cooling"
        case .drained: return "drained"
        case .needsLogin: return "login"
        case .windowFull: return "full"
        case .meterFull: return "metered"
        case .refused: return "refused"
        }
    }

    public var text: String { text(now: Date()) }

    public func text(now: Date) -> String {
        switch self {
        case .switchedOff: return L("turned off in Settings")
        case .capped(let kind): return L("usage cap reached on the %@ window", kind.title.lowercased())
        case .coolingDown(let until): return L("cooling down after a 429 · %@", Format.countdown(until, now: now))
        case .drained: return L("spent, says the upstream")
        case .needsLogin: return L("needs a new sign-in")
        case .windowFull(let kind, _): return L("%@ window at the switch threshold", kind.title)
        case .meterFull: return L("token or request allowance at the switch threshold")
        case .refused: return L("the upstream refused its last request")
        }
    }
}

/// An account's own health, as opposed to a window filling up.
public enum Health: String, Codable, Sendable, Equatable {
    case ok
    case coolingDown
    case drained
    case needsLogin
}
