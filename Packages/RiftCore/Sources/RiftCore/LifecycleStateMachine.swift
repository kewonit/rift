public enum LifecycleEvent: Sendable, Equatable {
    case requestActivation
    case approvalRequired
    case activationSucceeded
    case beginConfiguration
    case configurationSaved(enabled: Bool)
    case permissionDenied(String)
    case configurationStale
    case beginReplacement
    case beginUninstall
    case uninstallSucceeded
    case fail(String)
}

public enum LifecycleTransitionError: Error, Sendable, Equatable {
    case invalidTransition(from: LifecycleState, event: LifecycleEvent)
}

public struct LifecycleStateMachine: Sendable {
    public private(set) var state: LifecycleState

    public init(state: LifecycleState = .notInstalled) {
        self.state = state
    }

    @discardableResult
    public mutating func apply(_ event: LifecycleEvent) throws -> LifecycleState {
        let next: LifecycleState
        switch (state, event) {
        case (.notInstalled, .requestActivation),
             (.disabled, .requestActivation),
             (.failed, .requestActivation):
            next = .activating
        case (.activating, .approvalRequired):
            next = .awaitingApproval
        case (.activating, .activationSucceeded),
             (.awaitingApproval, .activationSucceeded),
             (.replacing, .activationSucceeded):
            next = .active
        case (.active, .beginConfiguration),
             (.stale, .beginConfiguration):
            next = .savingFilterConfiguration
        case (.savingFilterConfiguration, .configurationSaved(let enabled)):
            next = enabled ? .enabled : .disabled
        case (_, .permissionDenied(let message)):
            next = .denied(message: message)
        case (.savingFilterConfiguration, .configurationStale):
            next = .stale
        case (.activating, .beginReplacement),
             (.enabled, .beginReplacement):
            next = .replacing
        case (_, .beginUninstall):
            next = .uninstalling
        case (.uninstalling, .uninstallSucceeded):
            next = .notInstalled
        case (_, .fail(let message)):
            next = .failed(message: message)
        default:
            throw LifecycleTransitionError.invalidTransition(from: state, event: event)
        }
        state = next
        return next
    }
}
