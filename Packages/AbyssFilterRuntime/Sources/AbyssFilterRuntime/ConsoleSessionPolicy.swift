import AbyssCore

public enum ConsoleSessionPolicy {
    public static func permitsInteractivePolicy(
        authorizedUID: UInt32,
        currentConsoleUID: UInt32?,
        flowOwner: FlowOwner
    ) -> Bool {
        guard currentConsoleUID == authorizedUID else { return false }
        switch flowOwner {
        case .user(let uid): return uid == authorizedUID
        case .system: return true
        case .unknown: return false
        }
    }

    public static func restrictedAction(for decision: Decision) -> FilterAction {
        guard decision.filter.winningRuleID != nil else { return .allow }
        switch decision.filter.action {
        case .allow: return .allow
        case .deny: return .deny
        case .ask: return .allow
        }
    }
}
