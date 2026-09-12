import Foundation

/// A tolerant JSON value. The control-plane payloads are decoded into this once
/// and then read field by field, so a field that is missing or has an
/// unexpected type degrades to `nil` instead of failing the whole snapshot —
/// the installed proxy can be older or newer than the app.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public static func parse(_ data: Data) throws -> JSON {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSON(any: any)
    }

    public init(any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String:
            self = .string(s)
        case let a as [Any]:
            self = .array(a.map(JSON.init(any:)))
        case let d as [String: Any]:
            self = .object(d.mapValues(JSON.init(any:)))
        default:
            self = .null
        }
    }

    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    public var isNull: Bool { if case .null = self { return true } else { return false } }
    public var double: Double? { if case .number(let d) = self { return d } else { return nil } }
    public var int: Int? { double.flatMap { $0.isFinite && abs($0) < 9e15 ? Int($0) : nil } }
    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var array: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
    public var object: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }
    public var stringArray: [String] { (array ?? []).compactMap(\.string) }

    /// Timestamps arrive in two shapes: quota resets are epoch milliseconds,
    /// `rateLimitedUntil`/`lastUsed`/`probe.*At` are ISO-8601 strings.
    public var date: Date? {
        switch self {
        case .number(let d):
            guard d.isFinite, d > 0 else { return nil }
            let seconds = d >= 1e11 ? d / 1000 : d
            // Past year ~30000 nothing downstream (countdowns, `Int` conversions) is meaningful; a hostile value must not trap.
            guard seconds < 1e12 else { return nil }
            return Date(timeIntervalSince1970: seconds)
        case .string(let s):
            return JSON.parseISO8601(s)
        default:
            return nil
        }
    }

    static func parseISO8601(_ s: String) -> Date? {
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
        if let d = try? Date(s, strategy: Date.ISO8601FormatStyle()) { return d }
        return nil
    }

    /// Node-compatible pretty printer: 2-space indent, `"key": value`, keys sorted
    /// so a write is deterministic. `JSONSerialization` puts a space before the
    /// colon and would make every app write a whole-file diff against the proxy's.
    public func pretty() -> String {
        var out = ""
        render(into: &out, indent: 0)
        out.append("\n")
        return out
    }

    private func render(into out: inout String, indent: Int) {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch self {
        case .null: out.append("null")
        case .bool(let b): out.append(b ? "true" : "false")
        case .number(let d): out.append(JSON.formatNumber(d))
        case .string(let s): out.append(JSON.quote(s))
        case .array(let a):
            if a.isEmpty { out.append("[]"); return }
            out.append("[\n")
            for (i, v) in a.enumerated() {
                out.append(inner)
                v.render(into: &out, indent: indent + 2)
                out.append(i == a.count - 1 ? "\n" : ",\n")
            }
            out.append(pad + "]")
        case .object(let o):
            if o.isEmpty { out.append("{}"); return }
            out.append("{\n")
            let keys = o.keys.sorted()
            for (i, k) in keys.enumerated() {
                out.append(inner + JSON.quote(k) + ": ")
                o[k]!.render(into: &out, indent: indent + 2)
                out.append(i == keys.count - 1 ? "\n" : ",\n")
            }
            out.append(pad + "}")
        }
    }

    static func formatNumber(_ d: Double) -> String {
        if d.isNaN || d.isInfinite { return "null" }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return String(d)
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case "\u{08}": out.append("\\b")
            case "\u{0C}": out.append("\\f")
            default:
                if u.value < 0x20 { out.append(String(format: "\\u%04x", u.value)) } else { out.unicodeScalars.append(u) }
            }
        }
        out.append("\"")
        return out
    }
}
