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
        case .active: String(localized: "Active", bundle: .module)
        case .off: String(localized: "Off", bundle: .module)
        case .otherProfile: String(localized: "Other profile", bundle: .module)
        case .groupOff: String(localized: "Group off", bundle: .module)
        case .expired: String(localized: "Expired", bundle: .module)
        case .waitingForFilter: String(localized: "Waiting for filter", bundle: .module)
        case .notApplied: String(localized: "Not applied", bundle: .module)
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
