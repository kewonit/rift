import Foundation

public enum OperationMode: String, Sendable, Hashable, Codable {
    case alert
    case silentAllow
    case silentDeny
    case filterOff
    case degradedFallback
}

public enum NotificationDisposition: String, Sendable, Hashable, Codable {
    case none
    case notify
}

public enum PrivacyDisposition: String, Sendable, Hashable, Codable {
    case visible
    case hidden
}

public enum DecisionCategory: String, Sendable, Hashable, Codable {
    case filter
    case notification
    case privacy
}

public enum UnresolvedReason: String, Sendable, Hashable, Codable {
    case noMatchingRule
    case endpointUnavailable
    case hostnameUnavailable
    case portUnavailable
    case identityUnavailable
    case ownerUnavailable
    case unsupportedProtocol
    case expiryMetadataUnavailable
    case ambiguousPrecedence
}

public struct DecisionIssue: Sendable, Hashable, Codable {
    public let category: DecisionCategory
    public let reason: UnresolvedReason

    public init(category: DecisionCategory, reason: UnresolvedReason) {
        self.category = category
        self.reason = reason
    }
}

public struct PrecedenceExplanation: Sendable, Hashable, Codable {
    public let priority: RulePriority
    public let destination: String
    public let port: String
    public let transportProtocol: String
    public let process: String
    public let owner: String
    public let direction: String
    public let action: String
    public let ambiguityResolvedByRuleID: Bool
}

public struct CategoryDecision<Action: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    public let action: Action
    public let winningRuleID: UUID?
    public let affectingRuleIDs: [UUID]
    public let explanation: PrecedenceExplanation?

    public init(
        action: Action,
        winningRuleID: UUID?,
        affectingRuleIDs: [UUID],
        explanation: PrecedenceExplanation?
    ) {
        self.action = action
        self.winningRuleID = winningRuleID
        self.affectingRuleIDs = affectingRuleIDs
        self.explanation = explanation
    }
}

public struct Decision: Sendable, Hashable, Codable {
    public let filter: CategoryDecision<FilterAction>
    public let notification: CategoryDecision<NotificationDisposition>
    public let privacy: CategoryDecision<PrivacyDisposition>
    public let issues: [DecisionIssue]
    public let earliestExpiry: Date?

    public init(
        filter: CategoryDecision<FilterAction>,
        notification: CategoryDecision<NotificationDisposition>,
        privacy: CategoryDecision<PrivacyDisposition>,
        issues: [DecisionIssue],
        earliestExpiry: Date?
    ) {
        self.filter = filter
        self.notification = notification
        self.privacy = privacy
        self.issues = issues
        self.earliestExpiry = earliestExpiry
    }
}
