import Foundation

public struct ReferenceRuleMatcher: Sendable {
    private let rules: [Rule]
    private let requirements: RuleRequirements

    public init(rules: [Rule]) {
        self.rules = rules
        self.requirements = RuleRequirements(rules: rules)
    }

    public func decision(
        for flow: FlowDescriptor,
        context: MatchContext,
        mode: OperationMode
    ) -> Decision {
        DecisionEvaluator.evaluate(
            rules: rules,
            requirements: requirements,
            flow: flow,
            context: context,
            mode: mode
        )
    }
}

public struct CompiledRuleMatcher: Sendable {
    private let index: CompiledRuleIndex
    private let requirements: RuleRequirements

    public init(rules: [Rule]) {
        index = CompiledRuleIndex(rules: rules)
        requirements = RuleRequirements(rules: rules)
    }

    public func decision(
        for flow: FlowDescriptor,
        context: MatchContext,
        mode: OperationMode
    ) -> Decision {
        return DecisionEvaluator.evaluate(
            rules: index.candidates(flow: flow, context: context),
            requirements: requirements,
            flow: flow,
            context: context,
            mode: mode
        )
    }
}

private enum MatcherCategory: CaseIterable {
    case filter
    case notification
    case privacy

    init(action: RuleAction) {
        switch action {
        case .filter: self = .filter
        case .notification: self = .notification
        case .privacy: self = .privacy
        }
    }

    var publicValue: DecisionCategory {
        switch self {
        case .filter: .filter
        case .notification: .notification
        case .privacy: .privacy
        }
    }
}

private struct CategoryRequirements: Sendable {
    var hasRules = false
    var needsHostname = false
    var needsPort = false
    var needsIdentity = false
    var hasTemporaryRule = false
}

private struct RuleRequirements: Sendable {
    private var filter = CategoryRequirements()
    private var notification = CategoryRequirements()
    private var privacy = CategoryRequirements()

    init(rules: [Rule]) {
        for rule in rules {
            let category = MatcherCategory(action: rule.action)
            var value = self[category]
            value.hasRules = true
            if case .exactHostnameSet = rule.destination { value.needsHostname = true }
            if case .domainSet = rule.destination { value.needsHostname = true }
            if rule.port != nil { value.needsPort = true }
            if rule.process != .anyProcess { value.needsIdentity = true }
            if rule.expiresAt != nil { value.hasTemporaryRule = true }
            self[category] = value
        }
    }

    subscript(category: MatcherCategory) -> CategoryRequirements {
        get {
            switch category {
            case .filter: filter
            case .notification: notification
            case .privacy: privacy
            }
        }
        set {
            switch category {
            case .filter: filter = newValue
            case .notification: notification = newValue
            case .privacy: privacy = newValue
            }
        }
    }
}

private enum DecisionEvaluator {
    static func evaluate(
        rules: [Rule],
        requirements: RuleRequirements,
        flow: FlowDescriptor,
        context: MatchContext,
        mode: OperationMode
    ) -> Decision {
        let applicable = rules.compactMap { rule -> ApplicableRule? in
            guard case .success(let match) = RuleApplicability.evaluate(
                rule: rule,
                flow: flow,
                context: context
            ) else { return nil }
            return match
        }
        let sorted = applicable.sorted { RulePrecedence.precedes($0, $1) }
        let filterMatches = sorted.filter { if case .filter = $0.rule.action { true } else { false } }
        let notificationMatches = sorted.filter {
            if case .notification = $0.rule.action { true } else { false }
        }
        let privacyMatches = sorted.filter { if case .privacy = $0.rule.action { true } else { false } }

        var issues: [DecisionIssue] = []
        let filter = filterDecision(
            matches: filterMatches,
            requirements: requirements[.filter],
            flow: flow,
            context: context,
            mode: mode,
            issues: &issues
        )
        let notification = notificationDecision(
            matches: notificationMatches,
            requirements: requirements[.notification],
            flow: flow,
            context: context,
            issues: &issues
        )
        let privacy = privacyDecision(
            matches: privacyMatches,
            requirements: requirements[.privacy],
            flow: flow,
            context: context,
            issues: &issues
        )

        let earliestExpiry = applicable.compactMap(\.rule.expiresAt).min()
        return Decision(
            filter: filter,
            notification: notification,
            privacy: privacy,
            issues: issues,
            earliestExpiry: earliestExpiry
        )
    }

    private static func filterDecision(
        matches: [ApplicableRule],
        requirements: CategoryRequirements,
        flow: FlowDescriptor,
        context: MatchContext,
        mode: OperationMode,
        issues: inout [DecisionIssue]
    ) -> CategoryDecision<FilterAction> {
        if case .unsupported = flow.transportProtocol {
            issues.append(DecisionIssue(category: .filter, reason: .unsupportedProtocol))
            return CategoryDecision(
                action: .allow,
                winningRuleID: nil,
                affectingRuleIDs: [],
                explanation: nil
            )
        }
        if mode == .filterOff {
            return CategoryDecision(
                action: .allow,
                winningRuleID: nil,
                affectingRuleIDs: matches.map(\.rule.id),
                explanation: nil
            )
        }
        guard let winner = matches.first, case .filter(let action) = winner.rule.action else {
            appendMissingIssue(.filter, requirements, flow, context, to: &issues)
            return CategoryDecision(
                action: fallback(for: mode),
                winningRuleID: nil,
                affectingRuleIDs: [],
                explanation: nil
            )
        }
        let ambiguous = matches.dropFirst().first.map {
            RulePrecedence.tiedBeforeRuleID(winner, $0)
        } ?? false
        appendMetadataAndAmbiguityIssues(
            category: .filter,
            ambiguous: ambiguous,
            requirements: requirements,
            context: context,
            to: &issues
        )
        return CategoryDecision(
            action: action,
            winningRuleID: winner.rule.id,
            affectingRuleIDs: matches.map(\.rule.id),
            explanation: RulePrecedence.explanation(for: winner, ambiguous: ambiguous)
        )
    }

    private static func notificationDecision(
        matches: [ApplicableRule],
        requirements: CategoryRequirements,
        flow: FlowDescriptor,
        context: MatchContext,
        issues: inout [DecisionIssue]
    ) -> CategoryDecision<NotificationDisposition> {
        guard let winner = matches.first else {
            appendMissingIssue(.notification, requirements, flow, context, to: &issues)
            return CategoryDecision(action: .none, winningRuleID: nil, affectingRuleIDs: [], explanation: nil)
        }
        let ambiguous = matches.dropFirst().first.map {
            RulePrecedence.tiedBeforeRuleID(winner, $0)
        } ?? false
        appendMetadataAndAmbiguityIssues(
            category: .notification,
            ambiguous: ambiguous,
            requirements: requirements,
            context: context,
            to: &issues
        )
        return CategoryDecision(
            action: .notify,
            winningRuleID: winner.rule.id,
            affectingRuleIDs: matches.map(\.rule.id),
            explanation: RulePrecedence.explanation(for: winner, ambiguous: ambiguous)
        )
    }

    private static func privacyDecision(
        matches: [ApplicableRule],
        requirements: CategoryRequirements,
        flow: FlowDescriptor,
        context: MatchContext,
        issues: inout [DecisionIssue]
    ) -> CategoryDecision<PrivacyDisposition> {
        guard let winner = matches.first else {
            appendMissingIssue(.privacy, requirements, flow, context, to: &issues)
            return CategoryDecision(action: .visible, winningRuleID: nil, affectingRuleIDs: [], explanation: nil)
        }
        let ambiguous = matches.dropFirst().first.map {
            RulePrecedence.tiedBeforeRuleID(winner, $0)
        } ?? false
        appendMetadataAndAmbiguityIssues(
            category: .privacy,
            ambiguous: ambiguous,
            requirements: requirements,
            context: context,
            to: &issues
        )
        return CategoryDecision(
            action: .hidden,
            winningRuleID: winner.rule.id,
            affectingRuleIDs: matches.map(\.rule.id),
            explanation: RulePrecedence.explanation(for: winner, ambiguous: ambiguous)
        )
    }

    private static func fallback(for mode: OperationMode) -> FilterAction {
        switch mode {
        case .alert: .ask
        case .silentAllow, .filterOff, .degradedFallback: .allow
        case .silentDeny: .deny
        }
    }

    private static func appendMissingIssue(
        _ category: DecisionCategory,
        _ requirements: CategoryRequirements,
        _ flow: FlowDescriptor,
        _ context: MatchContext,
        to issues: inout [DecisionIssue]
    ) {
        guard requirements.hasRules else { return }
        let reason: UnresolvedReason
        switch flow.transportProtocol {
        case .unsupported:
            reason = .unsupportedProtocol
        default:
            if flow.destinationEndpoint == nil {
                reason = .endpointUnavailable
            } else if requirements.needsHostname, flow.observedHostname == nil {
                reason = .hostnameUnavailable
            } else if requirements.needsPort, flow.destinationEndpoint?.port == nil {
                reason = .portUnavailable
            } else if requirements.needsIdentity,
                      flow.sourceAppIdentity == nil,
                      flow.sourceProcessIdentity == nil {
                reason = .identityUnavailable
            } else if flow.owner == .unknown {
                reason = .ownerUnavailable
            } else if requirements.hasTemporaryRule,
                      context.policyTime.expiryMetadata == .unavailable {
                reason = .expiryMetadataUnavailable
            } else {
                reason = .noMatchingRule
            }
        }
        issues.append(DecisionIssue(category: category, reason: reason))
    }

    private static func appendMetadataAndAmbiguityIssues(
        category: DecisionCategory,
        ambiguous: Bool,
        requirements: CategoryRequirements,
        context: MatchContext,
        to issues: inout [DecisionIssue]
    ) {
        if requirements.hasTemporaryRule, context.policyTime.expiryMetadata == .unavailable {
            issues.append(DecisionIssue(category: category, reason: .expiryMetadataUnavailable))
        }
        if ambiguous {
            issues.append(DecisionIssue(category: category, reason: .ambiguousPrecedence))
        }
    }
}
