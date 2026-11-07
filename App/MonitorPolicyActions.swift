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
                let action = fixtureRuleActions[row.id]
                return (row.id, MonitorRuleCoverage(
                    state: action == nil ? .noRule : .exact, currentAction: action
                ))
            })
        }
#endif
        guard let repository,
              let snapshot = try await monitorCoverageCache.snapshot(load: {
                  try await repository.ruleWorkspaceSnapshot()
              }) else { return [:] }
        let enforcementState = PolicyEnforcementPresentation.state(
            persistedState: snapshot.enforcementState,
            desiredTuple: snapshot.desiredTuple,
            handshake: lastHandshake
        )
        return try await monitorCoverageCache.evaluate(
            rows,
            snapshot: snapshot,
            enforcementState: enforcementState
        )
    }

    /// What a rule action from the Map did.
    struct MonitorRuleChange {
        let ruleIDs: Set<UUID>
        /// `nil` when the rules already did this, so nothing was saved.
        let result: ConfigurationMutationResult?
    }

    func applyExactMonitorRule(
        for row: MonitorEventRow,
        action: FilterAction,
        elevatedOverrideConfirmed: Bool = false
    ) async throws -> MonitorRuleChange {
#if DEBUG
        if isUIFixture {
            fixtureRuleActions[row.id] = action
            fixtureLastRuleRowID = row.id
            ruleChanges.noteChange()
            return MonitorRuleChange(ruleIDs: [], result: .enforced(backupFailed: false))
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
        let overrideBlocklist = coverage.ruleIDs.contains { id in
            configuration.rules.first { $0.id == id }?.priority == .blocklistDeny
        }
        if action == .allow, overrideBlocklist, !elevatedOverrideConfirmed {
            throw RuleCommandError.elevatedOverrideRequiresConfirmation
        }
        let priority: RulePriority = action == .allow && overrideBlocklist ? .elevatedUser : .normal
        let ruleDraft = ManualRuleDraft(
            action: .filter(action),
            priority: priority,
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
            note: "Created from a recent connection"
        )
        try await validateManualDraft(ruleDraft, editingRuleID: nil)
        let now = Date()
        let plan = try MonitorRulePlan.plan(
            action: action,
            priority: priority,
            target: MonitorRuleTarget(seed: seed),
            flow: row.event.flow,
            configuration: configuration,
            now: now
        ) {
            try Rule(
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
        }
        switch plan {
        case .alreadyDecided(let ruleID):
            return MonitorRuleChange(ruleIDs: ruleID.map { [$0] } ?? [], result: nil)
        case .overridden(let ruleID):
            throw RuleCommandError.overriddenByRule(ruleID)
        case .changed(let rules, let affected):
            ruleChanges.nextChangeName = action == .deny ? "Block" : "Allow"
            let result = try await mutateRules(
                expectedGeneration: snapshot.generation,
                kind: "monitorExactRule"
            ) { _ in rules }
            return MonitorRuleChange(ruleIDs: affected, result: result)
        }
    }
}
