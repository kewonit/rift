import Foundation
import RiftCore
import RiftIPC

/// What happened to a connection, separate from why it happened.
public enum MonitorOutcome: Sendable, Hashable {
    case allowed
    case blocked
}

/// Why a connection ended up allowed or blocked.
public enum MonitorDecisionCause: Sendable, Hashable {
    case rule
    case yourAnswer
    case mode
    case alertTimedOut
    case alertUnavailable
    case noActiveRules
}

/// The three groups Rift counts. Every decision belongs to exactly one, so
/// totals always add up.
public enum MonitorTally: Sendable, Hashable {
    case allowed
    case blocked
    /// Allowed, but no rule or answer decided it.
    case noRule
}

extension RuntimeEvent {
    public var outcome: MonitorOutcome { action == .deny ? .blocked : .allowed }

    public var cause: MonitorDecisionCause {
        switch reason {
        case .concreteDecision: winningRuleID == nil ? .yourAnswer : .rule
        case .unmatchedModeFallback: .mode
        case .promptDeadlineFallback: .alertTimedOut
        case .promptUnavailableFallback: .alertUnavailable
        case .noActivePolicy: .noActiveRules
        }
    }

    public var tally: MonitorTally {
        if outcome == .blocked { return .blocked }
        return reason == .concreteDecision ? .allowed : .noRule
    }

    /// Why this happened, in a sentence that stays true for every mode.
    public var causeSentence: String {
        let blocked = outcome == .blocked
        return switch cause {
        case .rule:
            blocked ? String(localized: "A rule blocked it.", bundle: .module)
                : String(localized: "A rule allowed it.", bundle: .module)
        case .yourAnswer:
            blocked ? String(localized: "You blocked it when Rift asked.", bundle: .module)
                : String(localized: "You allowed it when Rift asked.", bundle: .module)
        case .mode:
            blocked ? String(localized: "No rule decided this, so your mode blocked it.", bundle: .module)
                : String(localized: "No rule decided this, so your mode allowed it.", bundle: .module)
        case .alertTimedOut:
            blocked ? String(localized: "The alert timed out, so it was blocked.", bundle: .module)
                : String(localized: "The alert timed out, so it was allowed.", bundle: .module)
        case .alertUnavailable:
            blocked ? String(localized: "Rift couldn’t show an alert, so it was blocked.", bundle: .module)
                : String(localized: "Rift couldn’t show an alert, so it was allowed.", bundle: .module)
        case .noActiveRules:
            blocked ? String(localized: "No rules were active, so it was blocked.", bundle: .module)
                : String(localized: "No rules were active, so it was allowed.", bundle: .module)
        }
    }
}
