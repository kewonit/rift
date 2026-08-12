import RiftControl
import RiftCore
import Foundation

extension ControlPlaneController {
    func monitorRuleCoverage(
        for rows: [MonitorEventRow]
    ) async throws -> [String: MonitorRuleCoverage] {
#if DEBUG
        if isUIFixture {
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let state: MonitorRuleCoverageState = fixtureRuleActions[row.id] == nil
                    ? .noRule : .exact
                return (row.id, MonitorRuleCoverage(state: state))
            })
        }
#endif
        guard let snapshot = try await repository?.ruleWorkspaceSnapshot() else { return [:] }
        let enforcementState = PolicyEnforcementPresentation.state(
            persistedState: snapshot.enforcementState,
            desiredTuple: snapshot.desiredTuple,
            handshake: lastHandshake
        )
        return MonitorCoverageEvaluator.evaluate(
            rows,
            configuration: snapshot.configuration,
            enforcementState: enforcementState,
            desiredTuple: snapshot.desiredTuple
        )
    }

    func applyExactMonitorRule(
        for row: MonitorEventRow,
        action: FilterAction,
        elevatedOverrideConfirmed: Bool = false
    ) async throws {
#if DEBUG
        if isUIFixture {
            fixtureRuleActions[row.id] = action
            return
        }
#endif
        guard action != .ask,
              let seed = MonitorExactRuleSeed.make(from: row),
              let snapshot = try await repository?.ruleWorkspaceSnapshot() else {
            throw RuleCommandError.missingConfiguration
        }
        let configuration = snapshot.configuration
        let enforcementState = PolicyEnforcementPresentation.state(
            persistedState: snapshot.enforcementState,
            desiredTuple: snapshot.desiredTuple,
            handshake: lastHandshake
        )
        let coverage = MonitorCoverageEvaluator.evaluate(
            [row], configuration: configuration, enforcementState: enforcementState,
            desiredTuple: snapshot.desiredTuple
        )[row.id] ?? MonitorRuleCoverage(state: .noRule)
        guard ![.savedPendingEnforcement, .persistedPendingProvider, .applyFailed]
            .contains(coverage.state) else {
            throw RuleCommandError.generationConflict
        }
        if coverage.state == .exact,
           let winnerID = coverage.winningRuleID,
           configuration.rules.first(where: { $0.id == winnerID })?.action == .filter(action) {
            return
        }
        let overrideBlocklist = coverage.ruleIDs.contains { id in
            configuration.rules.first { $0.id == id }?.priority == .blocklistDeny
        }
        if action == .allow, overrideBlocklist, !elevatedOverrideConfirmed {
            throw RuleCommandError.elevatedOverrideRequiresConfirmation
        }
        let ruleDraft = ManualRuleDraft(
            action: .filter(action),
            priority: action == .allow && overrideBlocklist ? .elevatedUser : .normal,
            process: seed.process,
            destination: seed.destination,
            transport: seed.transport,
            port: seed.port,
            direction: seed.direction,
            owner: seed.owner,
            profileID: configuration.activeProfileID,
            localGroupID: nil,
            expiresAt: nil,
            isEnabled: true,
            reviewState: .reviewed,
            note: "Created from Network Monitor"
        )
        try await validateManualDraft(ruleDraft, editingRuleID: nil)
        try await mutateRules(
            expectedGeneration: snapshot.generation,
            kind: "monitorExactRule"
        ) { rules in
            if coverage.state == .exact,
               let winnerID = coverage.winningRuleID,
               let current = rules.first(where: { $0.id == winnerID }),
               !current.flags.contains(.protected),
               !current.flags.contains(.sourceManaged) {
                return try rules.map { rule in
                    guard rule.id == winnerID else { return rule }
                    return try RuleMutation.edited(
                        rule,
                        action: ruleDraft.action,
                        priority: ruleDraft.priority,
                        process: rule.process,
                        destination: rule.destination,
                        transport: rule.transportProtocol,
                        port: rule.port,
                        direction: rule.direction,
                        owner: rule.owner,
                        profileID: rule.profileID,
                        localGroupID: rule.localGroupID,
                        expiresAt: rule.expiresAt,
                        isEnabled: true,
                        reviewState: .reviewed,
                        note: rule.notes,
                        now: Date()
                    )
                }
            }
            let now = Date()
            let rule = try Rule(
                id: UUID(),
                lineageID: configuration.lineageID,
                revision: 1,
                action: ruleDraft.action,
                priority: ruleDraft.priority,
                process: ruleDraft.process,
                destination: ruleDraft.destination,
                transportProtocol: ruleDraft.transport,
                port: ruleDraft.port,
                direction: ruleDraft.direction,
                owner: ruleDraft.owner,
                profileID: ruleDraft.profileID,
                localGroupID: nil,
                isEnabled: true,
                reviewState: .reviewed,
                notes: ruleDraft.note,
                createdAt: now,
                modifiedAt: now
            )
            return rules + [rule]
        }
    }
}
