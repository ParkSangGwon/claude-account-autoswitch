import Foundation

/// Stable identity of a configured account, independent of its label.
public struct AccountID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init() { rawValue = UUID().uuidString.lowercased() }
    public var description: String { rawValue }
}

/// The subscription behind an account, reduced to what rotation and the fleet total care about.
public enum Plan: Codable, Sendable, Equatable, Hashable {
    case pro
    case max
    case ultra
    case team(multiplier: Int)
    case unknown

    /// Claude's own words for the plan, as the profile endpoint reports them. Ultra still reports
    /// the `max_20x` tier it replaced, so the multiplier is what tells Max and Ultra apart.
    public init(tierText: String?, seatText: String?) {
        let tier = (tierText ?? "").lowercased()
        let multiplier: Int? = tier.contains("20x") ? 20 : tier.contains("5x") ? 5 : nil
        if (seatText ?? "").lowercased().hasPrefix("team") { self = .team(multiplier: multiplier ?? 1); return }
        if tier.contains("ultra") || multiplier == 20 { self = .ultra; return }
        if multiplier == 5 { self = .max; return }
        if tier.contains("pro") || tier == "default" { self = .pro; return }
        self = .unknown
    }

    /// How much one account counts for in the fleet total, in Pro plans of weekly allowance.
    public var weight: Int? {
        switch self {
        case .pro: return 1
        case .max: return 5
        case .ultra: return 10
        case .team(let m): return m
        case .unknown: return nil
        }
    }

    public var badge: String {
        switch self {
        case .pro: return "Pro"
        case .max: return "Max"
        case .ultra: return "Ultra"
        case .team(let m): return m > 1 ? "Team \(m)x" : "Team"
        case .unknown: return L("tier ?")
        }
    }

    /// Pro meters no Fable in the plan: every Fable request there is paid for in usage credits.
    public var includesFable: Bool { self != .pro }

    private enum CodingKeys: String, CodingKey { case pro, max, ultra, team, unknown }
    private enum MultiplierKeys: String, CodingKey { case multiplier }

    /// A config written before Max and Ultra stores `{"max":{"multiplier":20}}` for what is Ultra now.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no plan"))
        }
        func multiplier() -> Int? { try? c.nestedContainer(keyedBy: MultiplierKeys.self, forKey: key).decodeIfPresent(Int.self, forKey: .multiplier) }
        switch key {
        case .pro: self = .pro
        case .max: self = (multiplier() ?? 5) >= 20 ? .ultra : .max
        case .ultra: self = .ultra
        case .team: self = .team(multiplier: multiplier() ?? 1)
        case .unknown: self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pro: _ = c.nestedContainer(keyedBy: MultiplierKeys.self, forKey: .pro)
        case .max: _ = c.nestedContainer(keyedBy: MultiplierKeys.self, forKey: .max)
        case .ultra: _ = c.nestedContainer(keyedBy: MultiplierKeys.self, forKey: .ultra)
        case .team(let m):
            var n = c.nestedContainer(keyedBy: MultiplierKeys.self, forKey: .team)
            try n.encode(m, forKey: .multiplier)
        case .unknown: _ = c.nestedContainer(keyedBy: MultiplierKeys.self, forKey: .unknown)
        }
    }
}

public struct Organization: Codable, Sendable, Equatable, Hashable {
    public var name: String?
    public var id: String?
    public init(name: String?, id: String?) { self.name = name; self.id = id }
}

public struct OAuthTokens: Codable, Sendable, Equatable {
    public var access: String
    public var refresh: String?
    public var expiresAt: Date?
    public init(access: String, refresh: String?, expiresAt: Date?) { self.access = access; self.refresh = refresh; self.expiresAt = expiresAt }
}

/// What goes on the wire in place of the client's own credential.
public enum Credential: Codable, Sendable, Equatable {
    case oauth(OAuthTokens)
    case apiKey(String)

    public var kind: CredentialKind { if case .apiKey = self { return .apiKey } else { return .subscription } }
}

public enum CredentialKind: String, Codable, Sendable, Equatable {
    case subscription
    case apiKey
}

/// A hard ceiling on how much of a window an account may use before it takes no requests at all.
public enum UsageCap: Codable, Sendable, Equatable {
    case uniform(Double)
    case perWindow([WindowKind: Double])

    public func limit(for kind: WindowKind) -> Double? {
        switch self {
        case .uniform(let v): return v
        case .perWindow(let table): return table[kind]
        }
    }
}

/// One configured account, exactly as the config file stores it.
public struct AccountRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: AccountID
    public var label: String
    /// Lower is preferred; a strictly lower rank preempts a healthy current account.
    public var rank: Int
    public var enabled: Bool
    /// Set aside until this passes, then back in rotation without anyone remembering to switch it on.
    public var skipUntil: Date?
    public var cap: UsageCap?
    public var plan: Plan
    public var planText: String?
    public var seatText: String?
    public var organization: Organization?
    /// Claude's account id, which the request body names in `metadata.user_id`.
    public var claudeAccountID: String?
    public var credential: Credential

    public init(id: AccountID = AccountID(), label: String, rank: Int = 0, enabled: Bool = true, skipUntil: Date? = nil, cap: UsageCap? = nil,
                plan: Plan = .unknown, planText: String? = nil, seatText: String? = nil, organization: Organization? = nil,
                claudeAccountID: String? = nil, credential: Credential) {
        self.id = id; self.label = label; self.rank = rank; self.enabled = enabled; self.skipUntil = skipUntil; self.cap = cap
        self.plan = plan; self.planText = planText; self.seatText = seatText; self.organization = organization
        self.claudeAccountID = claudeAccountID; self.credential = credential
    }

    public var kind: CredentialKind { credential.kind }

    /// The same Claude account seen twice (a second import, a re-login) is one record.
    public func sameIdentity(as other: AccountRecord) -> Bool {
        if let mine = claudeAccountID, let theirs = other.claudeAccountID {
            guard mine == theirs else { return false }
            let a = organization?.id, b = other.organization?.id
            return a == nil || b == nil || a == b
        }
        return label == other.label
    }
}
