import Foundation

/// The config document. Tokens live here and nowhere else.
public struct Configuration: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public struct Listen: Codable, Sendable, Equatable {
        public var port: Int
        public init(port: Int = 10912) { self.port = port }
    }

    public struct API: Codable, Sendable, Equatable {
        public var baseURL: String
        public init(baseURL: String = "https://api.anthropic.com") { self.baseURL = baseURL }
    }

    public struct Rotation: Codable, Sendable, Equatable {
        /// Usage (0…1) at which rotation leaves an account.
        public var switchAt: Double
        /// A window with its own line here overrides `switchAt`.
        public var switchAtByWindow: [WindowKind: Double]
        /// Give each new Claude Code session the least loaded preferred account.
        public var spreadSessions: Bool
        /// When every account is out, keep the request open this long before answering 429.
        public var waitWhenExhaustedSeconds: Int

        public init(switchAt: Double = 0.98, switchAtByWindow: [WindowKind: Double] = [:], spreadSessions: Bool = false, waitWhenExhaustedSeconds: Int = 0) {
            self.switchAt = switchAt; self.switchAtByWindow = switchAtByWindow; self.spreadSessions = spreadSessions; self.waitWhenExhaustedSeconds = waitWhenExhaustedSeconds
        }

        public func switchAt(_ kind: WindowKind) -> Double { switchAtByWindow[kind] ?? switchAt }

        enum CodingKeys: String, CodingKey { case switchAt, switchAtByWindow, spreadSessions, waitWhenExhaustedSeconds }

        /// `switchAtByWindow` is written `{"weekly": 0.9}`, the shape a person writing this file by
        /// hand reaches for. Swift's own dictionary encoding puts a non-string key in a flat array,
        /// so documents written before this still decode; a window name nobody knows is skipped.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Rotation()
            switchAt = try c.decodeIfPresent(Double.self, forKey: .switchAt) ?? d.switchAt
            spreadSessions = try c.decodeIfPresent(Bool.self, forKey: .spreadSessions) ?? d.spreadSessions
            waitWhenExhaustedSeconds = try c.decodeIfPresent(Int.self, forKey: .waitWhenExhaustedSeconds) ?? d.waitWhenExhaustedSeconds
            if let named = try? c.decodeIfPresent([String: Double].self, forKey: .switchAtByWindow) {
                switchAtByWindow = named.reduce(into: [:]) { table, pair in
                    if let kind = WindowKind(rawValue: pair.key) { table[kind] = pair.value }
                }
            } else {
                switchAtByWindow = try c.decodeIfPresent([WindowKind: Double].self, forKey: .switchAtByWindow) ?? [:]
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(switchAt, forKey: .switchAt)
            try c.encode(Dictionary(uniqueKeysWithValues: switchAtByWindow.map { ($0.key.rawValue, $0.value) }), forKey: .switchAtByWindow)
            try c.encode(spreadSessions, forKey: .spreadSessions)
            try c.encode(waitWhenExhaustedSeconds, forKey: .waitWhenExhaustedSeconds)
        }
    }

    public struct Quota: Codable, Sendable, Equatable {
        /// Background refresh from the usage endpoint; 0 turns it off.
        public var refreshEverySeconds: Int
        public init(refreshEverySeconds: Int = 300) { self.refreshEverySeconds = refreshEverySeconds }
    }

    /// What the engine learned while it ran, written back so a restart resumes from it instead of
    /// treating a spent account as fresh until the first probe lands. Not settings: the engine owns it.
    public struct Observed: Codable, Sendable, Equatable {
        public struct Account: Codable, Sendable, Equatable {
            public var id: AccountID
            public var windows: Windows
            public init(id: AccountID, windows: Windows) { self.id = id; self.windows = windows }
        }

        /// The account new requests started from when the engine last ran.
        public var lastActive: AccountID?
        public var accounts: [Account]

        public init(lastActive: AccountID? = nil, accounts: [Account] = []) {
            self.lastActive = lastActive; self.accounts = accounts
        }

        public func windows(of id: AccountID) -> Windows? { accounts.first { $0.id == id }?.windows }
    }

    public var version: Int
    public var listen: Listen
    public var api: API
    public var rotation: Rotation
    public var quota: Quota
    public var accounts: [AccountRecord]
    public var observed: Observed

    public init(version: Int = Configuration.currentVersion, listen: Listen = Listen(), api: API = API(), rotation: Rotation = Rotation(),
                quota: Quota = Quota(), accounts: [AccountRecord] = [], observed: Observed = Observed()) {
        self.version = version; self.listen = listen; self.api = api; self.rotation = rotation; self.quota = quota
        self.accounts = accounts; self.observed = observed
    }

    public static let defaults = Configuration()

    /// A document written by hand may leave sections out; each takes its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Configuration.currentVersion
        listen = try c.decodeIfPresent(Listen.self, forKey: .listen) ?? Listen()
        api = try c.decodeIfPresent(API.self, forKey: .api) ?? API()
        rotation = try c.decodeIfPresent(Rotation.self, forKey: .rotation) ?? Rotation()
        quota = try c.decodeIfPresent(Quota.self, forKey: .quota) ?? Quota()
        accounts = try c.decodeIfPresent([AccountRecord].self, forKey: .accounts) ?? []
        observed = try c.decodeIfPresent(Observed.self, forKey: .observed) ?? Observed()
    }

    public func account(_ id: AccountID?) -> AccountRecord? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    public func index(of id: AccountID) -> Int? { accounts.firstIndex { $0.id == id } }

    /// The port the listener will actually bind: an out-of-range value falls back to the default.
    public var effectivePort: Int { (1...65535).contains(listen.port) ? listen.port : Listen().port }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public enum ConfigError: Error, Sendable, Equatable {
    case notFound(String)
    case unreadable(String)
    case malformed(String)
    case writeFailed(String)

    public var message: String {
        switch self {
        case .notFound(let p): return L("No config at %@", p)
        case .unreadable(let why): return L("Cannot read the config: %@", why)
        case .malformed(let why): return L("The config is not valid: %@", why)
        case .writeFailed(let why): return L("Cannot write the config: %@", why)
        }
    }

    /// A decoder describes a failure in Swift types and coding keys, which tells a person nothing.
    /// What they need is the line of the document to go and look at.
    public static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        let context: DecodingError.Context
        var missingKey: String?
        switch decoding {
        case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c): context = c
        case .keyNotFound(let key, let c): context = c; missingKey = key.stringValue
        @unknown default: return error.localizedDescription
        }
        var path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        if let missingKey { path += ".\(missingKey)" }
        path = String(path.drop(while: { $0 == "." }))
        if path.isEmpty { return L("The file is not valid JSON") }
        return L("%@ is not the shape the app expects", path)
    }
}

/// Where the document lives and how it is written: a same-directory temp file, 0600, fsynced,
/// renamed over the target, so a crash mid-write leaves the old document intact.
public struct ConfigStore: Sendable, Equatable {
    public static let envOverride = "CLAUDE_AUTOSWITCH_CONFIG"
    public let path: URL

    public init(path: URL) { self.path = path }

    /// `$CLAUDE_AUTOSWITCH_CONFIG`, else `~/Library/Application Support/Claude AutoSwitch/config.json`.
    public static func resolvePath(env: [String: String] = ProcessInfo.processInfo.environment, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let p = env[envOverride], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return home.appending(path: "Library/Application Support/Claude AutoSwitch/config.json")
    }

    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: path.path) else { throw ConfigError.notFound(path.path) }
        let data: Data
        do { data = try Data(contentsOf: path) } catch { throw ConfigError.unreadable(error.localizedDescription) }
        do { return try Configuration.decoder().decode(Configuration.self, from: data) } catch { throw ConfigError.malformed(ConfigError.describe(error)) }
    }

    public func save(_ configuration: Configuration) throws {
        let data: Data
        do { data = try Configuration.encoder().encode(configuration) } catch { throw ConfigError.writeFailed(error.localizedDescription) }
        try write(data)
    }

    /// The raw editor's path: bytes that already parsed as a document.
    public func write(_ data: Data) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: (path.path as NSString).resolvingSymlinksInPath)
        let dir = target.deletingLastPathComponent()
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) } catch { throw ConfigError.writeFailed(error.localizedDescription) }
        let temp = dir.appending(path: ".\(target.lastPathComponent).\(UUID().uuidString.prefix(8)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw ConfigError.writeFailed(String(cString: strerror(errno))) }
        var failure: String?
        data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = Foundation.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 { failure = String(cString: strerror(errno)); return }
                offset += n
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = String(cString: strerror(errno)) }
        close(fd)
        if failure == nil, chmod(temp.path, 0o600) != 0 { failure = String(cString: strerror(errno)) }
        if failure == nil, rename(temp.path, target.path) != 0 { failure = String(cString: strerror(errno)) }
        if let failure {
            unlink(temp.path)
            throw ConfigError.writeFailed(failure)
        }
    }
}
