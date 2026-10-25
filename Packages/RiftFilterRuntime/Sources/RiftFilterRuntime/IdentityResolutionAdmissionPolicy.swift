import RiftCore
import RiftIPC

public enum PendingFlowAdmissionResult: Sendable, Equatable {
    case admitted
    case duplicate
    case capacityExceeded
}

public enum PendingFlowAdmissionPolicy {
    public static func classify(
        currentCount: Int,
        containsFlowID: Bool,
        capacity: Int
    ) -> PendingFlowAdmissionResult {
        if containsFlowID { return .duplicate }
        return currentCount < capacity ? .admitted : .capacityExceeded
    }
}

public enum IdentityAdmissionPrivacy: Sendable, Equatable {
    case visible
    case hidden
    case unresolved
}

public struct IdentityAdmissionFallback: Sendable, Equatable {
    public let action: FilterAction
    public let reason: RuntimeEventReason
    public let privacy: IdentityAdmissionPrivacy

    public var permitsMetadataRecord: Bool { privacy == .visible }
    public var shouldReport: Bool { privacy == .visible }
}

public enum IdentityResolutionAdmissionPolicy {
    public static func fallback(
        for decision: Decision,
        identityResolutionFailed: Bool = false
    ) -> IdentityAdmissionFallback {
        let action: FilterAction
        let reason: RuntimeEventReason
        switch decision.filter.action {
        case .ask:
            action = .allow
            reason = .promptUnavailableFallback
        case .allow, .deny:
            action = decision.filter.action
            reason = decision.filter.winningRuleID == nil
                ? .unmatchedModeFallback : .concreteDecision
        }

        let privacy: IdentityAdmissionPrivacy
        if identityResolutionFailed {
            privacy = .unresolved
        } else if decision.privacy.action == .hidden {
            privacy = .hidden
        } else if decision.issues.contains(DecisionIssue(
            category: .privacy,
            reason: .identityUnavailable
        )) {
            privacy = .unresolved
        } else {
            privacy = .visible
        }
        return IdentityAdmissionFallback(action: action, reason: reason, privacy: privacy)
    }
}
