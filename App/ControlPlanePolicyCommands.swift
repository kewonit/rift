import AbyssControl
import AbyssCore
import AbyssIPC
import Foundation

extension ControlPlaneController {
    func answerWithRule(
        _ prompt: PromptRequest,
        action: FilterAction,
        duration: TimeInterval?,
        profileID: UUID?,
        destinationScope: AlertDestinationScope,
        allowSystemOwner: Bool,
        note: String
    ) async throws -> ConfigurationMutationResult {
        guard action != .ask, let repository else {
            throw RuleCommandError.missingConfiguration
        }
        guard pendingPrompts.contains(prompt), Date() < prompt.deadline else {
            throw ControlPlaneSafetyError.stalePrompt
        }
        guard let draft = try await repository.currentConfiguration(),
              let currentDesired = try await repository.newestDesiredPolicy() else {
            throw RuleCommandError.missingConfiguration
        }
        let handshake = try await client.handshake()
        let now = Date()
        try ControlPlaneSafety.validateDurablePrompt(
            prompt,
            pendingPrompts: pendingPrompts,
            handshake: handshake,
            desiredPolicy: currentDesired.tuple,
            configuration: draft,
            requestedProfileID: profileID,
            now: now
        )
        let rule = try AlertRuleBuilder.build(
            prompt: prompt,
            action: action,
            lineageID: draft.lineageID,
            authorizedUID: draft.authorizedUID,
            expiresAt: duration.map { now.addingTimeInterval($0) },
            profileID: profileID,
            destinationScope: destinationScope,
            allowSystemOwner: allowSystemOwner,
            notes: note,
            now: now
        )
        let updated = ControlPlaneController.copy(draft, rules: draft.rules + [rule])
        let desired = try await repository.save(
            updated,
            extensionHighWater: handshake.acceptedGenerationHighWater,
            expectedGeneration: prompt.generation,
            commandKind: "alertRule",
            redactedSummary: action.rawValue,
            now: now
        )
        return await finishSavedMutation(
            desired, lineageID: draft.lineageID, backupTime: now
        )
    }

    func policyDefinitions() async throws -> (
        groups: [LocalRuleGroup], profiles: [PolicyProfile], active: UUID?
    ) {
        guard let draft = try await repository?.currentConfiguration() else { return ([], [], nil) }
        return (draft.localGroups, draft.profiles, draft.activeProfileID)
    }

    func blocklistSources() async throws -> [BlocklistSource] {
        guard let draft = try await repository?.currentConfiguration() else { return [] }
        return draft.blocklists
    }

    @discardableResult
    func importBlocklist(data: Data, name: String) async throws -> ConfigurationMutationResult {
        try await BlocklistIngestion.ingest(data: data, name: name) { [self] preparation in
            try await self.importPreparedBlocklist(preparation)
        }
    }

    private func importPreparedBlocklist(
        _ preparation: BlocklistImportPreparation
    ) async throws -> ConfigurationMutationResult {
        try await mutateConfiguration(kind: "importBlocklist") { draft in
            try PolicyDefinitionValidator.rejectCollision(
                preparation.name, existing: draft.blocklists.map { ($0.id, $0.name) }
            )
            let result = try BlocklistImportBuilder.build(
                preparation: preparation, lineageID: draft.lineageID, now: Date()
            )
            return Self.copy(
                draft,
                rules: draft.rules + result.rules,
                blocklists: draft.blocklists + [result.source]
            )
        }
    }

    @discardableResult
    func setBlocklist(_ id: UUID, enabled: Bool) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "toggleBlocklist") { draft in
            guard draft.blocklists.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            let now = Date()
            let sources = draft.blocklists.map { source in
                guard source.id == id else { return source }
                return BlocklistSource(
                    id: source.id, name: source.name, importedAt: source.importedAt,
                    entryCount: source.entryCount,
                    domainEntryCount: source.domainEntryCount,
                    addressEntryCount: source.addressEntryCount,
                    contentHash: source.contentHash,
                    status: enabled ? .active : .disabled
                )
            }
            let rules = try draft.rules.map { rule in
                guard case .blocklist(let sourceID) = rule.source, sourceID == id else { return rule }
                return try RuleMutation.managedEnabled(rule, value: enabled, now: now)
            }
            return Self.copy(draft, rules: rules, blocklists: sources)
        }
    }

    @discardableResult
    func removeBlocklist(_ id: UUID) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "removeBlocklist") { draft in
            guard draft.blocklists.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            let rules = draft.rules.filter { rule in
                guard case .blocklist(let sourceID) = rule.source else { return true }
                return sourceID != id
            }
            let disabled = try BlocklistEntryOverrides.retainingKnownEntries(
                draft.disabledBlocklistEntries, in: rules
            )
            return Self.copy(
                draft, rules: rules,
                blocklists: draft.blocklists.filter { $0.id != id },
                disabledBlocklistEntries: disabled
            )
        }
    }

    func policyPresentation() async throws -> PolicyPresentation {
        guard let draft = try await repository?.currentConfiguration() else {
            return PolicyPresentation(
                baseMode: .silentAllow,
                effectiveMode: .silentAllow,
                profile: nil
            )
        }
        refreshCurrentMode(draft.operationMode)
        return PolicyPresentation(configuration: draft)
    }

    func ruleIdentityChoices() async throws -> [RuleIdentityChoice] {
        var choices: [ProcessCondition: Bool] = [.anyProcess: false]
        if let draft = try await repository?.currentConfiguration() {
            for rule in draft.rules where rule.process != .anyProcess {
                choices[rule.process, default: false] = choices[rule.process, default: false]
                    || rule.owner == .system
            }
        }
        if let rows = try await history?.page(limit: 1_000) {
            for row in rows {
                let flow = row.event.flow
                let permitsSystemOwner = flow.owner == .system
                if let app = flow.sourceAppIdentity {
                    choices[.exact(app), default: false] = choices[.exact(app), default: false]
                        || permitsSystemOwner
                }
                if let process = flow.sourceProcessIdentity {
                    choices[.exact(process), default: false] = choices[.exact(process), default: false]
                        || permitsSystemOwner
                }
                if let app = flow.sourceAppIdentity,
                   let helper = flow.sourceProcessIdentity,
                   app != helper {
                    let pair = ProcessCondition.appViaHelper(app: app, helper: helper)
                    choices[pair, default: false] = choices[pair, default: false]
                        || permitsSystemOwner
                }
            }
        }
        return choices.map {
            RuleIdentityChoice(process: $0.key, permitsSystemOwner: $0.value)
        }.sorted {
            if $0.process == .anyProcess { return true }
            if $1.process == .anyProcess { return false }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    func validateManualDraft(_ draft: ManualRuleDraft, editingRuleID: UUID?) async throws {
        guard let configuration = try await repository?.currentConfiguration() else {
            throw RuleCommandError.missingConfiguration
        }
        guard draft.profileID == nil
                || configuration.profiles.contains(where: { $0.id == draft.profileID }),
              draft.localGroupID == nil
                || configuration.localGroups.contains(where: { $0.id == draft.localGroupID }) else {
            throw RuleCommandError.unknownDefinition
        }
        switch draft.owner {
        case .authorizedUser:
            break
        case .specificUser:
            throw RuleCommandError.invalidOwnerScope
        case .system:
            guard draft.process != .anyProcess else { throw RuleCommandError.invalidOwnerScope }
            let existingSystemIdentity = configuration.rules.contains {
                $0.id == editingRuleID && $0.owner == .system && $0.process == draft.process
            }
            let observedSystemIdentity = try await ruleIdentityChoices().contains {
                $0.process == draft.process && $0.permitsSystemOwner
            }
            guard existingSystemIdentity || observedSystemIdentity else {
                throw RuleCommandError.unavailableIdentity
            }
        }
    }

    @discardableResult
    func createManualRule(
        _ draft: ManualRuleDraft,
        expectedGeneration: UInt64
    ) async throws -> ConfigurationMutationResult {
        guard let lineageID = try await repository?.currentConfiguration()?.lineageID else {
            throw RuleCommandError.missingConfiguration
        }
        try await validateManualDraft(draft, editingRuleID: nil)
        return try await mutateRules(
            expectedGeneration: expectedGeneration, kind: "createRule"
        ) { rules in
            let now = Date()
            let rule = try Rule(
                id: UUID(), lineageID: lineageID, revision: 1,
                action: draft.action, priority: draft.priority, process: draft.process,
                destination: draft.destination, transportProtocol: draft.transport,
                port: draft.port, direction: draft.direction, owner: draft.owner,
                profileID: draft.profileID, localGroupID: draft.localGroupID,
                expiresAt: draft.expiresAt, isEnabled: draft.isEnabled,
                reviewState: draft.reviewState, notes: draft.note,
                createdAt: now, modifiedAt: now
            )
            return rules + [rule]
        }
    }

    @discardableResult
    func setBaseMode(_ mode: OperationMode) async throws -> ConfigurationMutationResult {
        guard mode != .degradedFallback else { throw RuleCommandError.invalidOwnerScope }
        return try await mutateConfiguration(kind: "setBaseMode") { draft in
            let effective = draft.profiles.first(where: { $0.id == draft.activeProfileID })?
                .operationModeOverride ?? mode
            return PolicyConfigurationDraft(
                lineageID: draft.lineageID, authorizedUID: draft.authorizedUID,
                operationMode: effective, baseOperationMode: mode,
                activeProfileID: draft.activeProfileID,
                enabledLocalGroupIDs: draft.enabledLocalGroupIDs, rules: draft.rules,
                localGroups: draft.localGroups, profiles: draft.profiles,
                blocklists: draft.blocklists,
                disabledBlocklistEntries: draft.disabledBlocklistEntries
            )
        }
    }

    @discardableResult
    func setEffectiveMode(_ mode: OperationMode) async throws -> ConfigurationMutationResult {
        guard mode != .degradedFallback else { throw RuleCommandError.invalidOwnerScope }
        return try await mutateConfiguration(kind: "setEffectiveMode") { draft in
            guard let activeID = draft.activeProfileID else {
                return PolicyConfigurationDraft(
                    lineageID: draft.lineageID, authorizedUID: draft.authorizedUID,
                    operationMode: mode, baseOperationMode: mode,
                    activeProfileID: nil, enabledLocalGroupIDs: draft.enabledLocalGroupIDs,
                    rules: draft.rules, localGroups: draft.localGroups,
                    profiles: draft.profiles, blocklists: draft.blocklists,
                    disabledBlocklistEntries: draft.disabledBlocklistEntries
                )
            }
            let now = Date()
            let profiles = draft.profiles.map { profile in
                guard profile.id == activeID else { return profile }
                return PolicyProfile(
                    id: profile.id, name: profile.name, symbolName: profile.symbolName,
                    operationModeOverride: mode, createdAt: profile.createdAt, modifiedAt: now
                )
            }
            return Self.copy(draft, operationMode: mode, profiles: profiles)
        }
    }

    @discardableResult
    func createProfile(name: String) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "createProfile") { draft in
            let now = Date()
            let validatedName = try PolicyDefinitionValidator.name(name)
            try PolicyDefinitionValidator.rejectCollision(
                validatedName, existing: draft.profiles.map { ($0.id, $0.name) }
            )
            let profile = PolicyProfile(
                id: UUID(), name: validatedName, symbolName: "person.crop.circle",
                operationModeOverride: nil, createdAt: now, modifiedAt: now
            )
            return Self.copy(draft, profiles: draft.profiles + [profile])
        }
    }

    @discardableResult
    func updateProfile(
        _ id: UUID,
        name: String? = nil,
        operationModeOverride: OperationMode?? = nil
    ) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "updateProfile") { draft in
            guard draft.profiles.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            let validatedName = try name.map(PolicyDefinitionValidator.name)
            if let validatedName {
                try PolicyDefinitionValidator.rejectCollision(
                    validatedName,
                    existing: draft.profiles.map { ($0.id, $0.name) },
                    excludingID: id
                )
            }
            let now = Date()
            let profiles = draft.profiles.map { profile in
                guard profile.id == id else { return profile }
                return PolicyProfile(
                    id: profile.id,
                    name: validatedName ?? profile.name,
                    symbolName: profile.symbolName,
                    operationModeOverride: operationModeOverride ?? profile.operationModeOverride,
                    createdAt: profile.createdAt,
                    modifiedAt: now
                )
            }
            let effective = draft.activeProfileID == id
                ? profiles.first(where: { $0.id == id })?.operationModeOverride
                    ?? draft.baseOperationMode
                : draft.operationMode
            return Self.copy(draft, operationMode: effective, profiles: profiles)
        }
    }

    @discardableResult
    func activateProfile(_ id: UUID?) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "activateProfile") { draft in
            guard id == nil || draft.profiles.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            let mode = draft.profiles.first(where: { $0.id == id })?.operationModeOverride
                ?? draft.baseOperationMode
            return Self.copy(draft, operationMode: mode, activeProfileID: id)
        }
    }

    @discardableResult
    func createLocalGroup(name: String) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "createGroup") { draft in
            let now = Date()
            let validatedName = try PolicyDefinitionValidator.name(name)
            try PolicyDefinitionValidator.rejectCollision(
                validatedName, existing: draft.localGroups.map { ($0.id, $0.name) }
            )
            let group = LocalRuleGroup(
                id: UUID(), name: validatedName, note: "", isEnabled: true,
                createdAt: now, modifiedAt: now
            )
            return Self.copy(
                draft,
                enabledGroups: draft.enabledLocalGroupIDs.union([group.id]),
                groups: draft.localGroups + [group]
            )
        }
    }

    @discardableResult
    func updateLocalGroup(
        _ id: UUID,
        name: String,
        note: String
    ) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "updateGroup") { draft in
            guard draft.localGroups.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            let validatedName = try PolicyDefinitionValidator.name(name)
            let validatedNote = try PolicyDefinitionValidator.note(note)
            try PolicyDefinitionValidator.rejectCollision(
                validatedName,
                existing: draft.localGroups.map { ($0.id, $0.name) },
                excludingID: id
            )
            let groups = draft.localGroups.map { group in
                guard group.id == id else { return group }
                return LocalRuleGroup(
                    id: group.id, name: validatedName, note: validatedNote,
                    isEnabled: group.isEnabled,
                    createdAt: group.createdAt, modifiedAt: Date()
                )
            }
            return Self.copy(draft, groups: groups)
        }
    }

    @discardableResult
    func setLocalGroup(_ id: UUID, enabled: Bool) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "toggleGroup") { draft in
            guard draft.localGroups.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            var enabledGroups = draft.enabledLocalGroupIDs
            if enabled { enabledGroups.insert(id) } else { enabledGroups.remove(id) }
            let groups = draft.localGroups.map { group in
                guard group.id == id else { return group }
                return LocalRuleGroup(
                    id: group.id, name: group.name, note: group.note, isEnabled: enabled,
                    createdAt: group.createdAt, modifiedAt: Date()
                )
            }
            return Self.copy(draft, enabledGroups: enabledGroups, groups: groups)
        }
    }

    @discardableResult
    func removeLocalGroup(
        _ id: UUID,
        deletingRules: Bool
    ) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "removeGroup") { draft in
            guard draft.localGroups.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            guard !draft.rules.contains(where: {
                $0.localGroupID == id
                    && ($0.flags.contains(.protected) || $0.flags.contains(.sourceManaged))
            }) else { throw RuleCommandError.protectedAssignments }
            let now = Date()
            let rules = try draft.rules.compactMap { rule -> Rule? in
                guard rule.localGroupID == id else { return rule }
                return deletingRules ? nil : try RuleMutation.removingGroup(rule, now: now)
            }
            return Self.copy(
                draft,
                enabledGroups: draft.enabledLocalGroupIDs.subtracting([id]),
                rules: rules,
                groups: draft.localGroups.filter { $0.id != id }
            )
        }
    }

    @discardableResult
    func removeProfile(
        _ id: UUID,
        deletingRules: Bool
    ) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "removeProfile") { draft in
            guard draft.profiles.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            guard !draft.rules.contains(where: {
                $0.profileID == id
                    && ($0.flags.contains(.protected) || $0.flags.contains(.sourceManaged))
            }) else { throw RuleCommandError.protectedAssignments }
            let now = Date()
            let rules = try draft.rules.compactMap { rule -> Rule? in
                guard rule.profileID == id else { return rule }
                return deletingRules ? nil : try RuleMutation.removingProfile(rule, now: now)
            }
            let removingActive = draft.activeProfileID == id
            return Self.copy(
                draft,
                operationMode: removingActive ? draft.baseOperationMode : draft.operationMode,
                activeProfileID: removingActive ? .some(nil) : nil,
                rules: rules,
                profiles: draft.profiles.filter { $0.id != id }
            )
        }
    }
}
