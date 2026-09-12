import Foundation

/// One poll's worth of the numbers worth keeping: the engine only knows "now", so
/// "was bob cooling down all afternoon" and "how fast did the week burn" come from here.
public struct HistorySample: Codable, Sendable, Equatable {
    public struct AccountSample: Codable, Sendable, Equatable {
        /// `ok`, or the blocker's code (`off`, `capped`, `cooling`, `drained`, `login`, `full`, `refused`).
        public var state: String
        public var session: Double?
        public var weekly: Double?

        public init(state: String, session: Double?, weekly: Double?) {
            self.state = state; self.session = session; self.weekly = weekly
        }
    }

    public var at: Date
    public var fleetSession: Double?
    public var fleetWeekly: Double?
    public var current: String?
    public var accounts: [String: AccountSample]

    public init(at: Date, fleetSession: Double?, fleetWeekly: Double?, current: String?, accounts: [String: AccountSample]) {
        self.at = at; self.fleetSession = fleetSession; self.fleetWeekly = fleetWeekly; self.current = current; self.accounts = accounts
    }

    public init(state: EngineState, at: Date) {
        self.at = at
        fleetSession = Fleet.total(state, .session)?.used
        fleetWeekly = Fleet.total(state, .weekly)?.used
        current = state.label(state.current)
        var acc: [String: AccountSample] = [:]
        for a in state.accounts {
            acc[a.label] = AccountSample(state: a.blocker?.code ?? "ok", session: a.windows[.session]?.used, weekly: a.windows[.weekly]?.used)
        }
        accounts = acc
    }
}

/// A bounded local record of samples: one a minute at most, seven days kept.
public struct HistoryStore: Codable, Sendable, Equatable {
    public static let retention: TimeInterval = 7 * 24 * 3600
    public static let minInterval: TimeInterval = 60

    public var samples: [HistorySample] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        samples = try c.decodeIfPresent([HistorySample].self, forKey: .samples) ?? []
    }

    /// Appends when the last sample is old enough; prunes what fell out of the window. Returns whether anything changed.
    @discardableResult
    public mutating func record(_ sample: HistorySample) -> Bool {
        if let last = samples.last, sample.at.timeIntervalSince(last.at) < HistoryStore.minInterval { return false }
        samples.append(sample)
        prune(now: sample.at)
        return true
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-HistoryStore.retention)
        if let first = samples.first, first.at < cutoff {
            samples.removeAll { $0.at < cutoff }
        }
    }

    public func samples(since: Date) -> ArraySlice<HistorySample> {
        guard let start = samples.firstIndex(where: { $0.at >= since }) else { return [] }
        return samples[start...]
    }

    /// Accounts that appear anywhere in the kept window, most recent first.
    public var accountLabels: [String] {
        var seen: [String] = []
        for s in samples.reversed() { for n in s.accounts.keys where !seen.contains(n) { seen.append(n) } }
        return seen
    }

    public static func load(from url: URL) -> HistoryStore {
        guard let data = try? Data(contentsOf: url), let store = try? JSONDecoder().decode(HistoryStore.self, from: data) else { return HistoryStore() }
        return store
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

/// A run of consecutive samples in one state, for the per-account strips.
public struct HistorySegment: Sendable, Equatable {
    public var from: Date
    public var to: Date
    /// An `AccountSample.state`, or `absent` for a gap.
    public var state: String
}

extension HistoryStore {
    /// The account's state over time, compressed into runs; gaps longer than three
    /// minutes (the app was not running) read as `absent`.
    public func segments(account: String, since: Date, until: Date) -> [HistorySegment] {
        var out: [HistorySegment] = []
        var runState: String?
        var runStart = since
        var lastAt = since
        func close(at: Date) {
            if let state = runState, at > runStart { out.append(HistorySegment(from: runStart, to: at, state: state)) }
        }
        for s in samples(since: since) where s.at <= until {
            if s.at.timeIntervalSince(lastAt) > 180, runState != nil {
                close(at: lastAt)
                out.append(HistorySegment(from: lastAt, to: s.at, state: "absent"))
                runState = nil
                runStart = s.at
            }
            let state = s.accounts[account]?.state ?? "absent"
            if state != runState {
                close(at: s.at)
                runState = state
                runStart = s.at
            }
            lastAt = s.at
        }
        close(at: min(until, lastAt.addingTimeInterval(HistoryStore.minInterval)))
        return out
    }

    /// (time, value) points for a sparkline.
    public func series(since: Date, until: Date, value: (HistorySample) -> Double?) -> [(Date, Double)] {
        samples(since: since).filter { $0.at <= until }.compactMap { s in value(s).map { (s.at, $0) } }
    }
}
