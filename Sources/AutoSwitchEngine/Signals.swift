import Foundation
import AutoSwitchCore

/// What a reply from Claude's API says about the account that made it: the
/// `anthropic-ratelimit-*` headers, folded into the account's windows.
enum Signals {
    struct Headers {
        private var map: [String: String] = [:]

        init(_ headers: [(String, String)]) { for (k, v) in headers { map[k.lowercased()] = v } }

        subscript(key: String) -> String? { map[key] }

        func ratio(_ key: String) -> Double? { map[key].flatMap(Double.init).map { $0 > 1 ? $0 / 100 : $0 } }

        func date(_ key: String) -> Date? {
            guard let raw = map[key] else { return nil }
            if let n = Double(raw) { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
            return ISO8601DateFormatter().date(from: raw)
        }

        func number(_ key: String) -> Double? { map[key].flatMap(Double.init) }
    }

    /// Header name stems per window. Fable's own week is metered under `7d_oi`.
    static let stems: [(WindowKind, String)] = [(.session, "5h"), (.weekly, "7d"), (.weeklyFable, "7d_oi")]

    static func absorb(_ raw: [(String, String)], into w: inout Windows, now: Date = Date()) {
        let h = Headers(raw)
        for (kind, stem) in stems {
            let used = h.ratio("anthropic-ratelimit-unified-\(stem)-utilization")
            let reset = h.date("anthropic-ratelimit-unified-\(stem)-reset")
            if let used {
                w[kind] = WindowReading(used: used, resetsAt: reset ?? w[kind]?.resetsAt, seenAt: now)
            } else if let reset, var r = w[kind] {
                r.resetsAt = reset; w[kind] = r
            }
        }
        if let status = h["anthropic-ratelimit-unified-status"] {
            // A rejection that neither window confirms is noise: the reply says which window is closed.
            // Absent window lines confirm nothing, so they leave the account in rotation — the same
            // reading `refusal` gives the very same headers.
            let five = h["anthropic-ratelimit-unified-5h-status"], week = h["anthropic-ratelimit-unified-7d-status"]
            let confirmed = five == "rejected" || week == "rejected"
            w.refusedAt = status == "rejected" && confirmed ? now : nil
        }
        if let limit = h.number("anthropic-ratelimit-tokens-limit"), let remaining = h.number("anthropic-ratelimit-tokens-remaining") {
            w.tokens = Meter(limit: limit, remaining: remaining)
        }
        if let limit = h.number("anthropic-ratelimit-requests-limit"), let remaining = h.number("anthropic-ratelimit-requests-remaining") {
            w.requests = Meter(limit: limit, remaining: remaining)
        }
        if let r = h.date("anthropic-ratelimit-tokens-reset") ?? h.date("anthropic-ratelimit-requests-reset") { w.metersResetAt = r }
    }

    /// What a 429 closed: a shared window (the account must cool down for `retry-after`) or only Fable's week.
    enum Refusal { case sharedWindow, fableWindow, plain }

    static func refusal(_ raw: [(String, String)]) -> Refusal {
        let h = Headers(raw)
        if h["anthropic-ratelimit-unified-5h-status"] == "rejected" || h["anthropic-ratelimit-unified-7d-status"] == "rejected" { return .sharedWindow }
        if h["anthropic-ratelimit-unified-7d_oi-status"] == "rejected" { return .fableWindow }
        return .plain
    }

    static func retryAfter(_ raw: [(String, String)], fallback: Double = 60) -> Double {
        raw.first { $0.0.caseInsensitiveCompare("retry-after") == .orderedSame }.flatMap { Double($0.1) } ?? fallback
    }

    /// The client draws its own limit banner from these headers. Relayed as they arrive they
    /// describe the one account that answered, so the account rotation is about to leave
    /// announces a limit the client will never hit — and the next reply, from the account that
    /// took over, takes it back. Rewritten to what the rotation can still serve, the banner
    /// tracks the fleet. With nothing left to serve, `allowance` is empty and the refusal
    /// reaches the client exactly as the upstream wrote it.
    static func rewrite(_ raw: [(String, String)], as allowance: [WindowKind: WindowReading]) -> [(String, String)] {
        guard !allowance.isEmpty else { return raw }
        let prefixes = stems.compactMap { kind, stem in allowance[kind].map { ("anthropic-ratelimit-unified-\(stem)", $0) } }
        let soonest = allowance.values.compactMap(\.resetsAt).min()
        return raw.map { key, value in
            let k = key.lowercased()
            guard k.hasPrefix("anthropic-ratelimit-unified-") else { return (key, value) }
            if k == "anthropic-ratelimit-unified-status" { return (key, "allowed") }
            if k == "anthropic-ratelimit-unified-reset" { return (key, soonest.map { format($0, like: value) } ?? value) }
            for (prefix, reading) in prefixes {
                switch k {
                case prefix + "-utilization": return (key, format(reading.used, like: value))
                case prefix + "-reset": return (key, reading.resetsAt.map { format($0, like: value) } ?? value)
                case prefix + "-status": return (key, "allowed")
                case prefix + "-surpassed-threshold": return (key, "false")
                default: continue
                }
            }
            return (key, value)
        }
    }

    /// A rewritten value keeps the shape the upstream used, so a client that parses one parses the other.
    private static func format(_ ratio: Double, like original: String) -> String {
        original.contains(".") ? String(format: "%.3f", ratio) : String(Int((ratio * 100).rounded()))
    }

    private static func format(_ date: Date, like original: String) -> String {
        guard let n = Double(original) else { return ISO8601DateFormatter().string(from: date) }
        return String(Int(n > 1e12 ? date.timeIntervalSince1970 * 1000 : date.timeIntervalSince1970))
    }
}

/// Reads `message_start` / `message_delta` usage out of an SSE stream as it passes, or out of a whole JSON body.
struct UsageMeter {
    struct Counts { var input = 0, output = 0, cacheRead = 0, cacheCreation = 0; var isEmpty: Bool { input == 0 && output == 0 } }
    private(set) var counts = Counts()
    private var line = Data()

    mutating func feed(_ chunk: Data) {
        for byte in chunk {
            if byte == 0x0A { consume(); line = Data() } else if line.count < 1_048_576 { line.append(byte) }
        }
    }

    private mutating func consume() {
        guard line.starts(with: Data("data: ".utf8)), let json = try? JSON.parse(line.dropFirst(6)) else { return }
        switch json["type"].string {
        case "message_start":
            let u = json["message"]["usage"]
            counts.input += u["input_tokens"].int ?? 0
            counts.cacheRead += u["cache_read_input_tokens"].int ?? 0
            counts.cacheCreation += u["cache_creation_input_tokens"].int ?? 0
        case "message_delta":
            counts.output += json["usage"]["output_tokens"].int ?? 0
        default: break
        }
    }

    static func counts(inBody data: Data) -> Counts {
        guard let json = try? JSON.parse(data) else { return Counts() }
        let u = json["usage"]
        return Counts(input: u["input_tokens"].int ?? 0, output: u["output_tokens"].int ?? 0, cacheRead: u["cache_read_input_tokens"].int ?? 0, cacheCreation: u["cache_creation_input_tokens"].int ?? 0)
    }
}
