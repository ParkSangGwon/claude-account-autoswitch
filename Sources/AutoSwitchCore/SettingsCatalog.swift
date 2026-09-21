import Foundation

public enum SettingsSection: String, Sendable, CaseIterable, Identifiable {
    case general, proxy, accounts, rotation, quota, history, advanced
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .general: return L("General")
        case .proxy: return L("Proxy")
        case .accounts: return L("Accounts")
        case .rotation: return L("Rotation")
        case .quota: return L("Quota")
        case .history: return L("History")
        case .advanced: return L("Advanced")
        }
    }
}

public enum FieldKind: Sendable, Equatable {
    case toggle
    case int(min: Int?, max: Int?, step: Int, unit: String?)
    case double(min: Double?, max: Double?, step: Double, unit: String?)
    case text(placeholder: String?)
    case picker([String])
    /// key → number; a missing key means "default".
    case keyedNumbers(keys: [String])
}

/// One editable value of the configuration, described as data so the settings panes render themselves.
public struct SettingField: Sendable, Equatable, Identifiable {
    public let id: String
    public let section: SettingsSection
    public let label: String
    public let help: String
    public let kind: FieldKind

    public init(_ id: String, _ section: SettingsSection, _ label: String, _ help: String, _ kind: FieldKind) {
        self.id = id; self.section = section; self.label = label; self.help = help; self.kind = kind
    }
}

public enum SettingsError: Error, Sendable, Equatable {
    case noSuchAccount(String)
    case invalid(String)

    public var message: String {
        switch self {
        case .noSuchAccount(let n): return L("No account named %@", n)
        case .invalid(let why): return why
        }
    }
}

/// The editable configuration, as a table the Rotation, Quota, Proxy and Accounts panes render from.
public enum SettingsCatalog {
    public static let windowKeys = ["default"] + WindowKind.allCases.map(\.rawValue)

    public static let fields: [SettingField] = [
        SettingField("rotation.switchAt", .rotation, "Switch threshold", "Usage at which rotation leaves an account. Reported usage arrives in whole percents.", .double(min: 1, max: 100, step: 1, unit: "%")),
        SettingField("rotation.switchAtByWindow", .rotation, "Per-bucket thresholds", "Override the threshold for one window; a missing window uses `default` (the value above).", .keyedNumbers(keys: windowKeys)),
        SettingField("rotation.spreadSessions", .rotation, "Session distribution", "Off: quota-driven rotation only. On: give each new Claude Code session the least loaded account among the preferred ones.", .picker(["off", "on"])),
        SettingField("rotation.waitWhenExhaustedSeconds", .rotation, "Hold on exhaustion", "Hold the request open until an account can serve instead of answering 429 when every account is spent. 0 returns 429 at once.", .int(min: 0, max: 3600, step: 30, unit: "s")),
        SettingField("quota.refreshEverySeconds", .quota, "Quota probe", "Background refresh of idle accounts from the usage endpoint (spends no quota). 0 turns it off; minimum 30 s.", .int(min: 0, max: 604_800, step: 60, unit: "s")),
        SettingField("quota.keepSessionOpen", .quota, "Keep the 5-hour window open", "Send one tiny request on each account as its five-hour window resets, so the next window runs on the clock instead of starting when you next sit down. Off by default: the request goes out on your account. A sleeping Mac cannot send it, and a reset it slept through is opened within a minute of waking.", .toggle),
        SettingField("listen.port", .proxy, "Port", "Local port the proxy listens on. The listener moves at once.", .int(min: 1, max: 65535, step: 1, unit: nil)),
        SettingField("api.baseURL", .proxy, "Upstream", "API base URL for Anthropic accounts.", .text(placeholder: "https://api.anthropic.com")),
    ]

    public static let planKeys = ["unknown", "pro", "max5", "max20", "team"]

    public static let accountFields: [SettingField] = [
        SettingField("cap", .accounts, "Usage cap", "Hard per-account cap: a fraction (0–1) or a per-window table. At the cap the account receives no requests at all.", .keyedNumbers(keys: windowKeys)),
        SettingField("plan", .accounts, "Plan", "What the account counts for in the fleet total. Read from Claude when the profile answers; set it here when it did not, or the account is left out of the total entirely.", .picker(planKeys)),
    ]

    public static func field(_ id: String) -> SettingField? { (fields + accountFields).first { $0.id == id } }
    public static func fields(in section: SettingsSection) -> [SettingField] { fields.filter { $0.section == section } }

    // MARK: - reading

    /// The value a form shows for a field: percents for thresholds, otherwise the number, text or choice as is.
    public static func value(_ field: SettingField, in c: Configuration) -> JSON? {
        switch field.id {
        case "rotation.switchAt": return .number(c.rotation.switchAt * 100)
        case "rotation.switchAtByWindow":
            var o: [String: JSON] = ["default": .number(c.rotation.switchAt)]
            for (k, v) in c.rotation.switchAtByWindow { o[k.rawValue] = .number(v) }
            return .object(o)
        case "rotation.spreadSessions": return .string(c.rotation.spreadSessions ? "on" : "off")
        case "rotation.waitWhenExhaustedSeconds": return .number(Double(c.rotation.waitWhenExhaustedSeconds))
        case "quota.refreshEverySeconds": return .number(Double(c.quota.refreshEverySeconds))
        case "quota.keepSessionOpen": return .bool(c.quota.keepSessionOpen)
        case "listen.port": return .number(Double(c.listen.port))
        case "api.baseURL": return .string(c.api.baseURL)
        default: return nil
        }
    }

    public static func accountValue(_ field: SettingField, in r: AccountRecord) -> JSON? {
        if field.id == "plan" { return .string(planKey(r.plan)) }
        guard field.id == "cap", let cap = r.cap else { return nil }
        switch cap {
        case .uniform(let v): return .object(["default": .number(v)])
        case .perWindow(let t): return .object(Dictionary(uniqueKeysWithValues: t.map { ($0.key.rawValue, JSON.number($0.value)) }))
        }
    }

    static func planKey(_ plan: Plan) -> String {
        switch plan {
        case .pro: return "pro"
        case .max(let m): return m >= 20 ? "max20" : "max5"
        case .team: return "team"
        case .unknown: return "unknown"
        }
    }

    // MARK: - writing

    public static func apply(_ field: SettingField, value: JSON?, to c: inout Configuration) throws {
        switch field.id {
        case "rotation.switchAt":
            guard let pct = value?.double, (1...100).contains(pct) else { throw SettingsError.invalid(L("Threshold must be between 1 and 100")) }
            c.rotation.switchAt = pct / 100
        case "rotation.switchAtByWindow":
            // Keyed tables carry fractions (0–1); the editor shows them as percents.
            var table: [WindowKind: Double] = [:]
            for kind in WindowKind.allCases { if let v = value?[kind.rawValue].double { table[kind] = v } }
            if let d = value?["default"].double { c.rotation.switchAt = d }
            c.rotation.switchAtByWindow = table
        case "rotation.spreadSessions":
            c.rotation.spreadSessions = value?.string == "on" || value?.bool == true
        case "rotation.waitWhenExhaustedSeconds":
            c.rotation.waitWhenExhaustedSeconds = max(0, Format.safeInt(value?.double ?? 0))
        case "quota.refreshEverySeconds":
            c.quota.refreshEverySeconds = max(0, Format.safeInt(value?.double ?? 0))
        case "quota.keepSessionOpen":
            c.quota.keepSessionOpen = value?.bool == true
        case "listen.port":
            let p = Format.safeInt(value?.double ?? 0)
            guard (1...65535).contains(p) else { throw SettingsError.invalid(L("Port must be between 1 and 65535")) }
            c.listen.port = p
        case "api.baseURL":
            let s = (value?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil else { throw SettingsError.invalid(L("Upstream must be an http(s) URL")) }
            c.api.baseURL = s.hasSuffix("/") ? String(s.dropLast()) : s
        default:
            throw SettingsError.invalid(L("Unknown setting %@", field.id))
        }
    }

    public static func applyAccount(_ field: SettingField, value: JSON?, to r: inout AccountRecord) throws {
        if field.id == "plan" {
            switch value?.string {
            case "pro": r.plan = .pro
            case "max5": r.plan = .max(multiplier: 5)
            case "max20": r.plan = .max(multiplier: 20)
            case "team": r.plan = .team(multiplier: 1)
            case "unknown": r.plan = .unknown
            default: throw SettingsError.invalid(L("Unknown plan %@", value?.string ?? "-"))
            }
            // Claude's own words no longer describe what this says; a later probe may fill them in again.
            r.planText = nil
            r.seatText = nil
            return
        }
        guard field.id == "cap" else { throw SettingsError.invalid(L("Unknown setting %@", field.id)) }
        guard let o = value?.object, !o.isEmpty else { r.cap = nil; return }
        var table: [WindowKind: Double] = [:]
        for kind in WindowKind.allCases { if let v = o[kind.rawValue]?.double { table[kind] = v } }
        if let d = o["default"]?.double, table.isEmpty { r.cap = .uniform(d); return }
        if let d = o["default"]?.double { for kind in WindowKind.allCases where table[kind] == nil { table[kind] = d } }
        r.cap = table.isEmpty ? nil : .perWindow(table)
    }
}
