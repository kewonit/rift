import Foundation

public struct ExpiredRuleKey: Sendable, Hashable, Codable {
    public let lineageID: UUID
    public let ruleID: UUID
    public let revision: UInt64
    public let expiresAt: Date

    public init(lineageID: UUID, ruleID: UUID, revision: UInt64, expiresAt: Date) {
        self.lineageID = lineageID
        self.ruleID = ruleID
        self.revision = revision
        self.expiresAt = expiresAt
    }
}

public enum ExpiryMetadata: Sendable, Equatable {
    case available(alreadyExpired: Set<ExpiredRuleKey>)
    case unavailable
}

public struct PolicyTime: Sendable, Equatable {
    public let now: Date
    public let expiryMetadata: ExpiryMetadata

    public init(now: Date, expiryMetadata: ExpiryMetadata) {
        self.now = now
        self.expiryMetadata = expiryMetadata
    }

    public func eligibility(of rule: Rule) -> RuleTimeEligibility {
        guard let expiry = rule.expiresAt, let key = rule.expiryKey else { return .eligible }
        guard expiry > now else { return .expired }
        switch expiryMetadata {
        case .available(let alreadyExpired):
            return alreadyExpired.contains(key) ? .expired : .eligible
        case .unavailable:
            // Excluding all temporary rules prevents a clock rollback from
            // reviving a previously expired rule when tombstones are corrupt.
            return .expiryMetadataUnavailable
        }
    }
}

public enum RuleTimeEligibility: Sendable, Equatable {
    case eligible
    case expired
    case expiryMetadataUnavailable
}
