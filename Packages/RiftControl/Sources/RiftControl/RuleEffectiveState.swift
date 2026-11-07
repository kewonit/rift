import Foundation
import RiftCore

/// Whether a rule is actually doing anything right now, and if not, why not.
public enum RuleEffectiveState: Sendable, Hashable {
    case active
    case off
    case otherProfile
    case groupOff
    case expired
    case waitingForFilter
    case notApplied

    public var label: String {
        switch self {
        case .active: "Active"
        case .off: "Off"
        case .otherProfile: "Other profile"
        case .groupOff: "Group off"
        case .expired: "Expired"
        case .waitingForFilter: "Waiting for filter"
        case .notApplied: "Not applied"
        }
    }

    public static func resolve(
        rule: Rule,
        enforcement: PolicyOutboxState,
        context: RuleWorkspaceQueryContext?
    ) -> RuleEffectiveState {
        guard rule.isEnabled else { return .off }
        if let context {
            if let profile = rule.profileID, profile != context.activeProfileID { return .otherProfile }
            if let group = rule.localGroupID, !context.enabledLocalGroupIDs.contains(group) { return .groupOff }
            if let expiry = rule.expiresAt, expiry <= context.now { return .expired }
        }
        switch enforcement {
        case .enforced: return .active
        case .savedPendingEnforcement, .persistedPendingProvider: return .waitingForFilter
        case .applyFailed: return .notApplied
        }
    }
}
