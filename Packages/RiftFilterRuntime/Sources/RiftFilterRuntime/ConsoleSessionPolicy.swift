import RiftCore

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

    /// The verdict for a flow that can't use the interactive policy: before
    /// login, while another account is at the console, or for another
    /// account's or an unknown owner's flow. Nobody can answer an alert, so
    /// Ask becomes Allow. For the authorized account and root, the decision
    /// must come from a flow whose app identity was resolved, as it is at the
    /// console, so app rules apply and Block Unless Allowed keeps blocking
    /// unmatched flows. Other accounts and unknown owners get only explicit
    /// rules: rules never match them, so only blocklists can.
    public static func restrictedAction(
        for decision: Decision,
        flowOwner: FlowOwner,
        authorizedUID: UInt32
    ) -> FilterAction {
        switch decision.filter.action {
        case .allow, .ask:
            return .allow
        case .deny:
            if decision.filter.winningRuleID != nil { return .deny }
            return appliesAccountPolicy(to: flowOwner, authorizedUID: authorizedUID) ? .deny : .allow
        }
    }

    /// Whether the authorized account's rules and mode govern this owner's
    /// flows. Only these flows need their app identity resolved when the
    /// authorized account isn't at the console.
    public static func appliesAccountPolicy(to owner: FlowOwner, authorizedUID: UInt32) -> Bool {
        switch owner {
        case .user(let uid): uid == authorizedUID
        case .system: true
        case .unknown: false
        }
    }
}
