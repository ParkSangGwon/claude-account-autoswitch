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
    case max(multiplier: Int)
    case pro
    case team(multiplier: Int)
    case unknown

    /// Claude's own words for the plan, as the profile endpoint reports them.
    public init(tierText: String?, seatText: String?) {
        let tier = (tierText ?? "").lowercased()
        let team = (seatText ?? "").lowercased().hasPrefix("team")
        let multiplier: Int? = tier.contains("20x") ? 20 : tier.contains("5x") ? 5 : nil
        if let multiplier { self = team ? .team(multiplier: multiplier) : .max(multiplier: multiplier); return }
        if team { self = .team(multiplier: 1); return }
        if tier.contains("pro") || tier.contains("default") { self = .pro; return }
        self = .unknown
    }

    /// How much one account counts for in the fleet total: a Max 20x plan is twenty Pro plans.
    public var weight: Int? {
        switch self {
        case .max(let m): return m
        case .team(let m): return m
        case .pro: return 1
        case .unknown: return nil
        }
    }

    public var badge: String {
        switch self {
        case .max(let m): return "Max \(m)x"
        case .team(let m): return m > 1 ? "Team \(m)x" : "Team"
        case .pro: return "Pro"
        case .unknown: return L("tier ?")
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
    public var cap: UsageCap?
    public var plan: Plan
    public var planText: String?
    public var seatText: String?
    public var organization: Organization?
    /// Claude's account id, which the request body names in `metadata.user_id`.
    public var claudeAccountID: String?
    public var credential: Credential

    public init(id: AccountID = AccountID(), label: String, rank: Int = 0, enabled: Bool = true, cap: UsageCap? = nil,
                plan: Plan = .unknown, planText: String? = nil, seatText: String? = nil, organization: Organization? = nil,
                claudeAccountID: String? = nil, credential: Credential) {
        self.id = id; self.label = label; self.rank = rank; self.enabled = enabled; self.cap = cap
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
