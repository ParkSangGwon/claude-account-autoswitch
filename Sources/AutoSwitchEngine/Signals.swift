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
