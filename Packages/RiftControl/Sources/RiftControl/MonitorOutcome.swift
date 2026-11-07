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
        let verb = outcome == .blocked ? "blocked" : "allowed"
        return switch cause {
        case .rule: "A rule \(verb) it."
        case .yourAnswer: "You \(verb) it when Rift asked."
        case .mode: "No rule decided this, so your mode \(verb) it."
        case .alertTimedOut: "The alert timed out, so it was \(verb)."
        case .alertUnavailable: "Rift couldn’t show an alert, so it was \(verb)."
        case .noActiveRules: "No rules were active, so it was \(verb)."
        }
    }
}
