import RiftControl
import RiftCore
import RiftIPC
import Foundation

private enum ConfigurationMutationSavePlan {
    case connected(extensionHighWater: UInt64)
    case authenticatedOffline(AuthenticatedRootHighWater)

    var shouldApply: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum ConfigurationMutationResult: Sendable, Equatable {
    case enforced(backupFailed: Bool)
    case savedPending(backupFailed: Bool)
    case persistedPendingProvider(backupFailed: Bool)
    case applyFailed(backupFailed: Bool)

    init(state: PolicyOutboxState, backupFailed: Bool) {
        switch state {
        case .enforced: self = .enforced(backupFailed: backupFailed)
        case .savedPendingEnforcement: self = .savedPending(backupFailed: backupFailed)
        case .persistedPendingProvider:
            self = .persistedPendingProvider(backupFailed: backupFailed)
        case .applyFailed: self = .applyFailed(backupFailed: backupFailed)
        }
    }

    var message: String {
        let base: String
        let backupFailed: Bool
        switch self {
        case .enforced(let failed):
            base = "Saved and enforced."
            backupFailed = failed
        case .savedPending(let failed):
            base = "Saved. Enforcement confirmation is pending."
            backupFailed = failed
        case .persistedPendingProvider(let failed):
            base = "Saved by the filter. Waiting for the provider."
            backupFailed = failed
        case .applyFailed(let failed):
            base = "Saved, but applying failed. Retry after Rift reconnects."
            backupFailed = failed
        }
        return backupFailed ? base + " Automatic backup failed." : base
    }

    var requiresAttention: Bool {
        if case .enforced(backupFailed: false) = self { return false }
        return true
    }
}

extension ControlPlaneController {
    @discardableResult
    func setRulesEnabled(
        _ ids: Set<UUID>, enabled: Bool, expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        return try await mutateRules(
            expectedGeneration: expectedGeneration, kind: "setEnabled"
        ) { rules in
            try rules.map { rule in
                guard ids.contains(rule.id),
                      !rule.flags.contains(.protected),
                      !rule.flags.contains(.sourceManaged) else { return rule }
                return try RuleMutation.enabled(rule, value: enabled, now: Date())
            }
        }
    }

    @discardableResult
    func markRulesReviewed(
        _ ids: Set<UUID>, reviewed: Bool, expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        return try await mutateRules(
            expectedGeneration: expectedGeneration, kind: "markReviewed"
        ) { rules in
            try rules.map { rule in
                guard ids.contains(rule.id),
                      !rule.flags.contains(.protected),
                      !rule.flags.contains(.sourceManaged) else { return rule }
                return try RuleMutation.reviewed(rule, value: reviewed, now: Date())
            }
        }
    }

    @discardableResult
    func assignRulesToGroup(
        _ ids: Set<UUID>, groupID: UUID?, expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        if let groupID {
            guard let draft = try await repository?.currentConfiguration(),
                  draft.localGroups.contains(where: { $0.id == groupID }) else {
                throw RuleCommandError.missingConfiguration
            }
        }
        return try await mutateRules(
            expectedGeneration: expectedGeneration, kind: "assignRulesToGroup"
        ) { rules in
            try rules.map { rule in
                guard ids.contains(rule.id),
                      !rule.flags.contains(.protected),
                      !rule.flags.contains(.sourceManaged) else { return rule }
                return try RuleMutation.assigned(
                    rule, profileID: rule.profileID, localGroupID: groupID, now: Date()
                )
            }
        }
    }

    @discardableResult
    func assignRulesToProfile(
        _ ids: Set<UUID>, profileID: UUID?, expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        if let profileID {
            guard let draft = try await repository?.currentConfiguration(),
                  draft.profiles.contains(where: { $0.id == profileID }) else {
                throw RuleCommandError.missingConfiguration
            }
        }
        return try await mutateRules(
            expectedGeneration: expectedGeneration, kind: "assignRulesToProfile"
        ) { rules in
            try rules.map { rule in
                guard ids.contains(rule.id),
                      !rule.flags.contains(.protected),
                      !rule.flags.contains(.sourceManaged) else { return rule }
                return try RuleMutation.assigned(
                    rule, profileID: profileID, localGroupID: rule.localGroupID, now: Date()
                )
            }
        }
    }

    @discardableResult
    func applyRuleWorkspaceDrop(
        _ ids: Set<UUID>,
        target: RuleWorkspaceDropTarget,
        operation: RuleWorkspaceDropOperation,
        newRuleIDs: [UUID],
        expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        guard let draft = try await repository?.currentConfiguration() else {
            throw RuleCommandError.missingConfiguration
        }
        switch target {
        case .localGroup(let id):
            guard draft.localGroups.contains(where: { $0.id == id }) else {
                throw RuleCommandError.missingConfiguration
            }
        case .profile(let id):
            guard draft.profiles.contains(where: { $0.id == id }) else {
                throw RuleCommandError.missingConfiguration
            }
        }
        return try await mutateRules(
            expectedGeneration: expectedGeneration,
            kind: operation == .copy ? "copyRulesToCollection" : "moveRulesToCollection"
        ) { rules in
            let plan = try RuleWorkspaceDropPlan(
                rules: rules,
                selectedRuleIDs: ids,
                target: target,
                operation: operation
            )
            return try plan.applying(to: rules, newRuleIDs: newRuleIDs, now: Date())
        }
    }

    @discardableResult
    func deleteRules(
        _ ids: Set<UUID>, expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        return try await mutateRules(
            expectedGeneration: expectedGeneration, kind: "deleteRules"
        ) { rules in
            rules.filter {
                !ids.contains($0.id)
                    || $0.flags.contains(.protected)
                    || $0.flags.contains(.sourceManaged)
            }
        }
    }

    @discardableResult
    func duplicateRule(
        _ id: UUID, expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        return try await mutateRules(
            expectedGeneration: expectedGeneration, kind: "duplicateRule"
        ) { rules in
            guard let source = rules.first(where: { $0.id == id }) else { return rules }
            return rules + [try RuleMutation.duplicate(source, now: Date())]
        }
    }

    @discardableResult
    func editRule(
        _ id: UUID, draft: ManualRuleDraft, expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        try await validateManualDraft(draft, editingRuleID: id)
        return try await mutateRules(
            expectedGeneration: expectedGeneration, kind: "editRule"
        ) { rules in
            try rules.map { rule in
                guard rule.id == id else { return rule }
                return try RuleMutation.edited(
                    rule, action: draft.action, priority: draft.priority, process: draft.process,
                    destination: draft.destination, transport: draft.transport, port: draft.port,
                    direction: draft.direction, owner: draft.owner, profileID: draft.profileID,
                    localGroupID: draft.localGroupID, expiresAt: draft.expiresAt,
                    isEnabled: draft.isEnabled, reviewState: draft.reviewState,
                    note: draft.note, now: Date()
                )
            }
        }
    }

    @discardableResult
    func applyRuleWorkspaceUndo(
        _ plan: RuleWorkspaceUndoPlan
    ) async throws -> ConfigurationMutationResult {
        try await mutateRules(
            expectedGeneration: plan.expectedGeneration,
            kind: "undoRuleCommand"
        ) { rules in
            try plan.restoring(
                currentRules: rules,
                currentGeneration: plan.expectedGeneration,
                now: Date()
            )
        }
    }

    @discardableResult
    func mutateRules(
        expectedGeneration: UInt64,
        kind: String,
        transform: ([Rule]) throws -> [Rule]
    ) async throws -> ConfigurationMutationResult {
        guard let repository,
              let draft = try await repository.currentConfiguration(),
              let currentDesired = try await repository.newestDesiredPolicy() else {
            throw RuleCommandError.missingConfiguration
        }
        guard currentDesired.tuple.generation == expectedGeneration else {
            throw RuleCommandError.generationConflict
        }
        let savePlan = try await configurationMutationSavePlan(
            localDesired: currentDesired.tuple
        )
        let rules = try transform(draft.rules)
        let updated = Self.copy(draft, rules: rules)
        let desired = try await saveConfigurationMutation(
            updated,
            repository: repository,
            savePlan: savePlan,
            expectedGeneration: currentDesired.tuple.generation,
            commandKind: kind,
            redactedSummary: "count=\(rules.count)",
            now: Date()
        )
        return await finishConfigurationMutation(
            desired,
            savePlan: savePlan,
            lineageID: draft.lineageID,
            backupTime: Date()
        )
    }

    func mutateConfiguration(
        kind: String,
        transform: (PolicyConfigurationDraft) throws -> PolicyConfigurationDraft
    ) async throws -> ConfigurationMutationResult {
        guard let repository,
              let draft = try await repository.currentConfiguration(),
              let currentDesired = try await repository.newestDesiredPolicy() else {
            throw RuleCommandError.missingConfiguration
        }
        let savePlan = try await configurationMutationSavePlan(
            localDesired: currentDesired.tuple
        )
        let updated = try transform(draft)
        let desired = try await saveConfigurationMutation(
            updated,
            repository: repository,
            savePlan: savePlan,
            expectedGeneration: currentDesired.tuple.generation,
            commandKind: kind,
            redactedSummary: kind,
            now: Date()
        )
        currentMode = updated.operationMode
        return await finishConfigurationMutation(
            desired,
            savePlan: savePlan,
            lineageID: updated.lineageID,
            backupTime: Date()
        )
    }

    private func configurationMutationSavePlan(
        localDesired: PolicyTuple
    ) async throws -> ConfigurationMutationSavePlan {
        guard !configurationRecoveryRequired,
              pendingRestoreBackupURL == nil,
              try await repository?.pendingRestoreRecovery() == nil else {
            throw OfflineMutationSafetyError.recoveryInProgress
        }
        switch state {
        case .connected:
            authenticatedRootHighWater = nil
            let handshake = try await client.handshake()
            let anchor = try OfflineMutationSafety.authenticate(
                handshake: handshake,
                localDesired: localDesired
            )
            authenticatedRootHighWater = anchor
            return .connected(
                extensionHighWater: anchor.acceptedGenerationHighWater
            )
        case .integrationUnavailable:
            guard let authenticatedRootHighWater else {
                throw OfflineMutationSafetyError.authenticatedHighWaterUnavailable
            }
            return .authenticatedOffline(authenticatedRootHighWater)
        case .idle, .databaseReady, .failed:
            throw OfflineMutationSafetyError.authenticatedHighWaterUnavailable
        }
    }

    private func saveConfigurationMutation(
        _ draft: PolicyConfigurationDraft,
        repository: PolicyRepository,
        savePlan: ConfigurationMutationSavePlan,
        expectedGeneration: UInt64,
        commandKind: String,
        redactedSummary: String,
        now: Date
    ) async throws -> DesiredPolicy {
        switch savePlan {
        case .connected(let extensionHighWater):
            return try await repository.save(
                draft,
                extensionHighWater: extensionHighWater,
                expectedGeneration: expectedGeneration,
                commandKind: commandKind,
                redactedSummary: redactedSummary,
                now: now
            )
        case .authenticatedOffline(let anchor):
            return try await repository.saveOffline(
                draft,
                authenticatedRoot: anchor,
                expectedGeneration: expectedGeneration,
                commandKind: commandKind,
                redactedSummary: redactedSummary,
                now: now
            )
        }
    }

    private func finishConfigurationMutation(
        _ desired: DesiredPolicy,
        savePlan: ConfigurationMutationSavePlan,
        lineageID: UUID,
        backupTime: Date
    ) async -> ConfigurationMutationResult {
        guard !savePlan.shouldApply else {
            return await finishSavedMutation(
                desired,
                lineageID: lineageID,
                backupTime: backupTime
            )
        }
        recordSavedDesiredPolicy(desired.tuple)
        var backupFailed = false
        do { _ = try await backups?.runIfNeeded(now: backupTime) }
        catch { backupFailed = true }
        requestReconnect()
        do {
            guard let repository,
                  let newest = try await repository.newestDesiredPolicy(),
                  newest.tuple == desired.tuple else {
                return .savedPending(backupFailed: backupFailed)
            }
            return ConfigurationMutationResult(
                state: newest.state,
                backupFailed: backupFailed
            )
        } catch {
            return .savedPending(backupFailed: backupFailed)
        }
    }

    func refreshAuthenticatedRootHighWater(from handshake: HandshakeState) async {
        authenticatedRootHighWater = nil
        guard !configurationRecoveryRequired, let repository else {
            return
        }
        do {
            guard let desired = try await repository.newestDesiredPolicy() else {
                authenticatedRootHighWater = nil
                return
            }
            authenticatedRootHighWater = try OfflineMutationSafety.authenticate(
                handshake: handshake,
                localDesired: desired.tuple
            )
        } catch {
            authenticatedRootHighWater = nil
        }
    }

    func finishSavedMutation(
        _ desired: DesiredPolicy,
        lineageID: UUID,
        backupTime: Date
    ) async -> ConfigurationMutationResult {
        var backupFailed = false
        do { _ = try await backups?.runIfNeeded(now: backupTime) }
        catch { backupFailed = true }
        var applyFailed = false
        do { try await reconcileSavedPolicy(desired, lineageID: lineageID) }
        catch { applyFailed = true }
        let fallback: ConfigurationMutationResult = applyFailed
            ? .applyFailed(backupFailed: backupFailed)
            : .savedPending(backupFailed: backupFailed)
        do {
            guard let repository,
                  let newest = try await repository.newestDesiredPolicy(),
                  newest.tuple == desired.tuple else {
                return fallback
            }
            return ConfigurationMutationResult(
                state: newest.state, backupFailed: backupFailed
            )
        } catch { return fallback }
    }

    static func copy(
        _ draft: PolicyConfigurationDraft,
        operationMode: OperationMode? = nil,
        activeProfileID: UUID?? = nil,
        enabledGroups: Set<UUID>? = nil,
        rules: [Rule]? = nil,
        groups: [LocalRuleGroup]? = nil,
        profiles: [PolicyProfile]? = nil,
        blocklists: [BlocklistSource]? = nil,
        disabledBlocklistEntries: Set<BlocklistEntry>? = nil
    ) -> PolicyConfigurationDraft {
        PolicyConfigurationDraft(
            lineageID: draft.lineageID,
            authorizedUID: draft.authorizedUID,
            operationMode: operationMode ?? draft.operationMode,
            baseOperationMode: draft.baseOperationMode,
            activeProfileID: activeProfileID ?? draft.activeProfileID,
            enabledLocalGroupIDs: enabledGroups ?? draft.enabledLocalGroupIDs,
            rules: rules ?? draft.rules,
            localGroups: groups ?? draft.localGroups,
            profiles: profiles ?? draft.profiles,
            blocklists: blocklists ?? draft.blocklists,
            disabledBlocklistEntries: disabledBlocklistEntries
                ?? draft.disabledBlocklistEntries
        )
    }
}
