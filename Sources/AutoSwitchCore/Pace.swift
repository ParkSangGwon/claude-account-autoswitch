import Foundation

/// How worried a bar should look.
public enum Severity: Int, Sendable, Equatable, Comparable, CaseIterable {
    case calm, brisk, hot, critical

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

/// Severity from pace: a window is fine while usage keeps up with the clock, and gets worse the
/// further usage runs ahead of the share of the window that has already passed. At the switch
/// threshold it is critical whatever the pace.
public enum Pace {
    /// Points of usage ahead of the clock that still count as brisk, then hot; beyond that critical.
    public static let briskLead = 5.0
    public static let hotLead = 15.0
    /// Without a reset time there is no clock to compare with; plain fill levels stand in.
    public static let plainBrisk = 0.7
    public static let plainHot = 0.9

    public static func severity(used: Double, resetsAt: Date?, length: TimeInterval?, threshold: Double?, now: Date = Date()) -> Severity {
        if let threshold, used >= threshold { return .critical }
        if let length, length > 0, let resetsAt {
            let remaining = resetsAt.timeIntervalSince(now)
            if remaining > 0 {
                let elapsed = max(0, length - remaining) / length
                let lead = (used - elapsed) * 100
                if lead <= 0 { return .calm }
                if lead <= briskLead { return .brisk }
                if lead <= hotLead { return .hot }
                return .critical
            }
        }
        return plain(used)
    }

    /// A fill with no window behind it (fleet totals, token meters).
    public static func plain(_ used: Double, brisk: Double = plainBrisk, hot: Double = plainHot) -> Severity {
        used < brisk ? .calm : used < hot ? .brisk : .critical
    }

    public static func severity(_ reading: WindowReading, kind: WindowKind, threshold: Double?, now: Date = Date()) -> Severity {
        severity(used: reading.used, resetsAt: reading.resetsAt, length: kind.length, threshold: threshold, now: now)
    }
}
