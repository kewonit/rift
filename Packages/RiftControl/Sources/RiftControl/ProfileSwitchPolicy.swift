import RiftCore
import Foundation

extension PolicyConfigurationDraft {
    /// The mode that applies once `profileID` is active, or the base mode for
    /// no profile.
    public func operationMode(activatingProfile profileID: UUID?) -> OperationMode {
        profiles.first { $0.id == profileID }?.operationModeOverride ?? baseOperationMode
    }

    /// Whether a caller nobody is watching, such as `riftctl`, may switch to
    /// `profileID`. A switch changes the mode and which profile rules apply,
    /// so it may not weaken the mode, turn off a profile rule that blocks,
    /// asks, or notifies, or turn on one that allows, asks, or hides.
    public func permitsUnattendedProfileSwitch(to profileID: UUID?, now: Date = Date()) -> Bool {
        guard profileID != activeProfileID else { return true }
        guard operationMode.permitsUnattendedSwitch(
            to: operationMode(activatingProfile: profileID)
        ) else { return false }
        // Only rules that would apply count: on, not expired, and not in a
        // group that's off.
        func applies(_ rule: Rule, in profile: UUID?) -> Bool {
            profile != nil && rule.profileID == profile && rule.isEnabled
                && (rule.localGroupID.map(enabledLocalGroupIDs.contains) ?? true)
                && (rule.expiresAt.map { $0 > now } ?? true)
        }
        let leaving = rules.filter { applies($0, in: activeProfileID) }
        let arriving = rules.filter { applies($0, in: profileID) }
        return leaving.allSatisfy(\.action.isSafeToTurnOff)
            && arriving.allSatisfy(\.action.isSafeToTurnOn)
    }
}

private extension RuleAction {
    /// Turning the rule on can only block more or show more.
    var isSafeToTurnOn: Bool { self == .filter(.deny) || self == .notification(.notify) }
    /// Turning the rule off can only block more or show more.
    var isSafeToTurnOff: Bool { self == .filter(.allow) || self == .privacy(.hide) }
}

extension OperationMode {
    /// Whether a caller nobody is watching, such as `riftctl`, may move the
    /// filter from this mode to `next`. Any process running as the user can
    /// run `riftctl`, so it may keep or strengthen protection, but never
    /// weaken it or make a change Rift would ask the user to confirm.
    public func permitsUnattendedSwitch(to next: OperationMode) -> Bool {
        guard next != self else { return true }
        return !next.needsConfirmation && next.protectionRank >= protectionRank
    }

    /// How much a mode holds back connections that no rule covers.
    private var protectionRank: Int {
        switch self {
        case .filterOff, .degradedFallback: 0
        case .silentAllow: 1
        case .alert: 2
        case .silentDeny: 3
        }
    }
}
