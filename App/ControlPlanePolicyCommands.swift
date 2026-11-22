import RiftControl
import RiftCore
import RiftIPC
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
        // A locked configuration takes no new rules; the alert can still be
        // answered once.
        try requireUnlocked()
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
        ruleChanges.nextChangeName = action == .deny ? "Block" : "Allow"
        ruleChanges.record(
            before: draft.rules, after: updated.rules,
            generation: desired.tuple.generation, isRedo: false
        )
        return await finishSavedMutation(
            desired, lineageID: draft.lineageID, backupTime: now
        )
    }

    /// One line for each rule in `ids` that still exists, in the given order.
    func ruleSummaries(_ ids: [UUID]) async -> [(id: UUID, text: String)] {
        guard !ids.isEmpty,
              let draft = try? await repository?.currentConfiguration() else { return [] }
        let rules = Dictionary(draft.rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lists = Dictionary(draft.blocklists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { id in
            guard let rule = rules[id] else { return nil }
            var listName: String?
            if case .blocklist(let source) = rule.source { listName = lists[source] }
            return (id, RuleRowViewValue.oneLineSummary(rule, blocklistName: listName))
        }
    }

    /// Temporary rules that are still running, soonest to end first, for the
    /// menu-bar panel.
    func runningTemporaryRules(now: Date, limit: Int) async -> [StatusTemporaryRule] {
        guard let draft = try? await repository?.currentConfiguration() else { return [] }
        return draft.rules
            .filter { rule in
                rule.isEnabled && !rule.flags.contains(.sourceManaged)
                    && rule.expiresAt.map { $0 > now } == true
                    // Only rules in effect: in the active profile and an enabled group.
                    && (rule.profileID == nil || rule.profileID == draft.activeProfileID)
                    && (rule.localGroupID.map(draft.enabledLocalGroupIDs.contains) ?? true)
            }
            .sorted { ($0.expiresAt ?? .distantFuture, $0.id.uuidString) < ($1.expiresAt ?? .distantFuture, $1.id.uuidString) }
            .prefix(limit)
            .compactMap { rule in
                guard let expiresAt = rule.expiresAt else { return nil }
                return StatusTemporaryRule(
                    id: rule.id,
                    action: rule.action,
                    summary: RuleRowViewValue.oneLineSummary(rule, blocklistName: nil),
                    expiresAt: expiresAt
                )
            }
    }

    /// How many of the person's own rules and blocklists exist.
    func ruleCounts() async -> (rules: Int, blocklists: Int)? {
        guard let draft = try? await repository?.currentConfiguration() else { return nil }
        let own = draft.rules.filter { !$0.flags.contains(.sourceManaged) }
        return (own.count, draft.blocklists.count)
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
    func importBlocklist(
        data: Data,
        name: String,
        sourceID: UUID = UUID()
    ) async throws -> ConfigurationMutationResult {
        try await BlocklistIngestion.ingest(data: data, name: name) { [self] preparation in
            try await self.importPreparedBlocklist(preparation, sourceID: sourceID)
        }
    }

    /// Replaces a blocklist's entries with a new version of the list, keeping
    /// its name, whether it's on, and entries turned off in Check Entry.
    /// Returns nil when the list hasn't changed.
    func replaceBlocklist(_ id: UUID, data: Data) async throws -> ConfigurationMutationResult? {
        guard let current = try await blocklistSources().first(where: { $0.id == id }) else {
            throw RuleCommandError.unknownDefinition
        }
        return try await BlocklistIngestion.ingest(data: data, name: current.name) { [self] preparation in
            guard preparation.contentHash != current.contentHash else { return nil }
            return try await self.replacePreparedBlocklist(id, preparation: preparation)
        }
    }

    private func replacePreparedBlocklist(
        _ id: UUID,
        preparation: BlocklistImportPreparation
    ) async throws -> ConfigurationMutationResult {
        // A new version of a subscribed list is the subscription doing what
        // the person set it up to do, so it isn't held up by the lock.
        try await mutateConfiguration(kind: "updateBlocklist", change: .automatic) { draft in
            guard let source = draft.blocklists.first(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            let result = try BlocklistImportBuilder.build(
                preparation: preparation, lineageID: draft.lineageID, now: Date(),
                sourceID: id, status: source.status
            )
            let rules = draft.rules.filter { rule in
                guard case .blocklist(let sourceID) = rule.source else { return true }
                return sourceID != id
            } + result.rules
            let disabled = try BlocklistEntryOverrides.retainingKnownEntries(
                draft.disabledBlocklistEntries, in: rules
            )
            return Self.copy(
                draft, rules: rules,
                blocklists: draft.blocklists.map { $0.id == id ? result.source : $0 },
                disabledBlocklistEntries: disabled
            )
        }
    }

    private func importPreparedBlocklist(
        _ preparation: BlocklistImportPreparation,
        sourceID: UUID
    ) async throws -> ConfigurationMutationResult {
        try await mutateConfiguration(kind: "importBlocklist") { draft in
            try PolicyDefinitionValidator.rejectCollision(
                preparation.name, existing: draft.blocklists.map { ($0.id, $0.name) }
            )
            let result = try BlocklistImportBuilder.build(
                preparation: preparation, lineageID: draft.lineageID, now: Date(), sourceID: sourceID
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
        let rows = isMinimalActivity ? recentActivityRows : (try await history?.page(limit: 1_000) ?? [])
        if !rows.isEmpty {
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
}
