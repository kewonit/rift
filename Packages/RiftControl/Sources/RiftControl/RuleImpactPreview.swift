import RiftCore
import Foundation

public struct RuleImpactPreviewSample: Sendable, Hashable, Identifiable {
    public let id: String
    public let application: String
    public let endpoint: String
    public let currentResult: String
    public let proposedResult: String
    public let candidateAffects: Bool
    public let candidateWins: Bool
    public let precedence: String?
}

public struct RuleImpactPreview: Sendable, Hashable {
    public let evaluatedCount: Int
    public let affectedCount: Int
    public let changedCount: Int
    public let samples: [RuleImpactPreviewSample]
}

public struct RulePreviewEnvironment: Sendable {
    public let configuration: PolicyConfigurationDraft
    public let samples: [MonitorEventRow]

    public init(configuration: PolicyConfigurationDraft, samples: [MonitorEventRow]) {
        self.configuration = configuration
        self.samples = Array(samples.prefix(RuleImpactPreviewEvaluator.maximumSamples))
    }
}

public enum RuleImpactPreviewEvaluator {
    public static let maximumSamples = 50
    private static let previewRuleID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF5, 1
    ))

    public static func evaluate(
        draft: ManualRuleDraft,
        editingRuleID: UUID?,
        environment: RulePreviewEnvironment,
        now: Date = Date()
    ) throws -> RuleImpactPreview {
        let candidate = try candidateRule(
            draft: draft,
            editingRuleID: editingRuleID,
            configuration: environment.configuration,
            now: now
        )
        let currentRules = environment.configuration.rules
        let proposedRules = currentRules.filter { $0.id != editingRuleID } + [candidate]
        let currentMatcher = CompiledRuleMatcher(rules: currentRules)
        let proposedMatcher = CompiledRuleMatcher(rules: proposedRules)
        let context = MatchContext(
            activeProfileID: environment.configuration.activeProfileID,
            enabledLocalGroupIDs: environment.configuration.enabledLocalGroupIDs,
            authorizedUID: environment.configuration.authorizedUID,
            policyTime: PolicyTime(now: now, expiryMetadata: .available(alreadyExpired: []))
        )
        let values = environment.samples.prefix(maximumSamples).map { row in
            sample(
                row,
                action: draft.action,
                candidateID: candidate.id,
                current: currentMatcher.decision(
                    for: row.event.flow,
                    context: context,
                    mode: environment.configuration.operationMode
                ),
                proposed: proposedMatcher.decision(
                    for: row.event.flow,
                    context: context,
                    mode: environment.configuration.operationMode
                )
            )
        }
        return RuleImpactPreview(
            evaluatedCount: values.count,
            affectedCount: values.filter(\.candidateAffects).count,
            changedCount: values.filter { $0.currentResult != $0.proposedResult }.count,
            samples: values.filter(\.candidateAffects)
        )
    }

    private static func candidateRule(
        draft: ManualRuleDraft,
        editingRuleID: UUID?,
        configuration: PolicyConfigurationDraft,
        now: Date
    ) throws -> Rule {
        if let editingRuleID,
           let existing = configuration.rules.first(where: { $0.id == editingRuleID }) {
            return try RuleMutation.edited(
                existing,
                action: draft.action,
                priority: draft.priority,
                process: draft.process,
                destination: draft.destination,
                transport: draft.transport,
                port: draft.port,
                direction: draft.direction,
                owner: draft.owner,
                profileID: draft.profileID,
                localGroupID: draft.localGroupID,
                expiresAt: draft.expiresAt,
                isEnabled: draft.isEnabled,
                reviewState: draft.reviewState,
                note: draft.note,
                now: now
            )
        }
        return try Rule(
            id: previewRuleID,
            lineageID: configuration.lineageID,
            revision: 1,
            action: draft.action,
            priority: draft.priority,
            process: draft.process,
            destination: draft.destination,
            transportProtocol: draft.transport,
            port: draft.port,
            direction: draft.direction,
            owner: draft.owner,
            profileID: draft.profileID,
            localGroupID: draft.localGroupID,
            expiresAt: draft.expiresAt,
            isEnabled: draft.isEnabled,
            reviewState: draft.reviewState,
            notes: draft.note,
            createdAt: now,
            modifiedAt: now
        )
    }

    private static func sample(
        _ row: MonitorEventRow,
        action: RuleAction,
        candidateID: UUID,
        current: Decision,
        proposed: Decision
    ) -> RuleImpactPreviewSample {
        let before: (String, UUID?, [UUID])
        let after: (String, UUID?, [UUID], PrecedenceExplanation?)
        switch action {
        case .filter:
            before = (current.filter.action.rawValue, current.filter.winningRuleID,
                      current.filter.affectingRuleIDs)
            after = (proposed.filter.action.rawValue, proposed.filter.winningRuleID,
                     proposed.filter.affectingRuleIDs, proposed.filter.explanation)
        case .notification:
            before = (current.notification.action.rawValue, current.notification.winningRuleID,
                      current.notification.affectingRuleIDs)
            after = (proposed.notification.action.rawValue, proposed.notification.winningRuleID,
                     proposed.notification.affectingRuleIDs, proposed.notification.explanation)
        case .privacy:
            before = (current.privacy.action.rawValue, current.privacy.winningRuleID,
                      current.privacy.affectingRuleIDs)
            after = (proposed.privacy.action.rawValue, proposed.privacy.winningRuleID,
                     proposed.privacy.affectingRuleIDs, proposed.privacy.explanation)
        }
        let beforeValue = before.0 + ruleSuffix(before.1)
        let afterValue = after.0 + ruleSuffix(after.1)
        return RuleImpactPreviewSample(
            id: row.id,
            application: MonitorQuery.applicationLabel(row),
            endpoint: MonitorQuery.endpointLabel(row),
            currentResult: beforeValue,
            proposedResult: afterValue,
            candidateAffects: after.2.contains(candidateID),
            candidateWins: after.1 == candidateID,
            precedence: after.1 == candidateID ? explanation(after.3) : nil
        )
    }

    private static func ruleSuffix(_ id: UUID?) -> String {
        id == nil ? " • fallback/no rule" : " • matched rule"
    }

    private static func explanation(_ value: PrecedenceExplanation?) -> String? {
        guard let value else { return nil }
        return [
            value.priority.rawValue,
            value.destination,
            value.port,
            value.transportProtocol,
            value.process,
            value.owner,
            value.direction,
        ].joined(separator: " • ")
    }
}
