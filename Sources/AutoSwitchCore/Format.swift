import Foundation

/// Numbers and times the way the app writes them.
public enum Format {
    /// The m / h / d tiering every countdown shares; `separator` sits between the two units.
    static func tiered(minutes: Int, separator: String) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let hrs = minutes / 60, rm = minutes % 60
        if hrs < 24 { return rm > 0 ? "\(hrs)h\(separator)\(rm)m" : "\(hrs)h" }
        let days = hrs / 24, rh = hrs % 24
        return rh > 0 ? "\(days)d\(separator)\(rh)h" : "\(days)d"
    }

    /// `45m`, `3h31m`, `2h`, `3d12h`; empty when past or unknown.
    public static func countdown(_ until: Date?, now: Date = Date()) -> String {
        guard let until else { return "" }
        let seconds = until.timeIntervalSince(now)
        // No window or cool-down lasts a year; anything further out is a broken clock.
        guard seconds.isFinite, seconds < 366 * 86_400, seconds > 0 else { return "" }
        return tiered(minutes: Int((seconds / 60).rounded(.up)), separator: "")
    }

    /// `12s`, `3h31m`: elapsed time for probe and uptime figures.
    public static func duration(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval < 1e15 else { return "-" }
        // A TimelineView tick can trail the poll that just landed by a few milliseconds: that is "now", not a dash.
        let totalSeconds = max(1, Int(max(0, interval).rounded()))
        if totalSeconds < 60 { return "\(totalSeconds)s" }
        return tiered(minutes: Int((Double(totalSeconds) / 60).rounded(.up)), separator: "")
    }

    public enum ResetStyle: String, Sendable, CaseIterable { case countdown, clock, both }

    /// "Resets in 3h 31m (Today 21:30)". Empty when the window has not started.
    public static func resetSentence(_ resetsAt: Date?, style: ResetStyle = .both, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let resetsAt else { return "" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return L("Reset overdue") }
        let spaced = spacedCountdown(remaining)
        let clock = clockText(resetsAt, now: now, calendar: calendar)
        switch style {
        case .countdown: return L("Resets in %@", spaced)
        case .clock: return L("Resets %@", clock)
        case .both: return L("Resets in %@ (%@)", spaced, clock)
        }
    }

    static func spacedCountdown(_ remaining: TimeInterval) -> String {
        if remaining < 60 { return L("under a minute") }
        guard remaining.isFinite, remaining < 1e15 else { return "" }
        return tiered(minutes: Int((remaining / 60).rounded(.up)), separator: " ")
    }

    static func clockText(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = localizedDate(date, date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return L("Today %@", time) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return L("Tomorrow %@", time) }
        if date.timeIntervalSince(now) < 6 * 24 * 3600 {
            return "\(date.formatted(Date.FormatStyle().weekday(.abbreviated).locale(L10n.locale))) \(time)"
        }
        return "\(date.formatted(Date.FormatStyle().month(.abbreviated).day().locale(L10n.locale))), \(time)"
    }

    /// A date in the app's language (weekday and month names, the Mac's own hour and order conventions).
    public static func localizedDate(_ date: Date, date dateStyle: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle) -> String {
        date.formatted(Date.FormatStyle(date: dateStyle, time: time).locale(L10n.locale))
    }

    /// Whole percent unless a tenth is meaningful; a dash for nothing.
    public static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let pct = min(1e6, max(-1e6, value * 100))
        if abs(pct - pct.rounded()) < 0.05 { return "\(Int(pct.rounded()))%" }
        return String(format: "%.1f%%", pct)
    }

    /// Whole percent, clamped so a hostile ratio (±inf, 1e300) cannot trap the conversion.
    public static func percentInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(1e6, max(-1e6, (value * 100).rounded())))
    }

    /// `Int(_:)` traps past ±9.2e18; anything from the wire or a hand-edited config goes through here.
    public static func safeInt(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int(min(1e15, max(-1e15, value.rounded())))
    }

    /// Money from minor units: `$12.34`, `EUR 5.00`.
    public static func money(minor: Double, currency: String, exponent: Int) -> String {
        let major = minor / pow(10, Double(exponent))
        let symbol = currency.uppercased() == "USD" ? "$" : currency.uppercased() + " "
        return symbol + String(format: "%.2f", major)
    }

    /// A short (1–3 letter) tag for an account: the first letters of the local part of its label.
    public static func tag(_ label: String) -> String {
        let local = label.split(separator: "@").first.map(String.init) ?? label
        let letters = local.filter { $0.isLetter || $0.isNumber }
        return String(letters.prefix(3)).lowercased()
    }
}
