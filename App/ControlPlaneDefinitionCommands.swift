import RiftControl
import RiftCore
import RiftIPC
import Foundation

extension ControlPlaneController {
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

    /// `unattended` is for `riftctl`, which any process running as the user
    /// can call. It refuses a switch that weakens protection; the user has to
    /// make that switch in Rift. `change` is automatic only for a switch by
    /// network, which the person set up and which carries on while locked.
    @discardableResult
    func activateProfile(
        _ id: UUID?,
        unattended: Bool = false,
        change: ConfigurationChange = .byHand
    ) async throws -> ConfigurationMutationResult {
        return try await mutateConfiguration(kind: "activateProfile", change: change) { draft in
            guard id == nil || draft.profiles.contains(where: { $0.id == id }) else {
                throw RuleCommandError.unknownDefinition
            }
            if unattended, !draft.permitsUnattendedProfileSwitch(to: id) {
                throw CLIRelayRefusal.profileSwitchNeedsConfirmation
            }
            let mode = draft.operationMode(activatingProfile: id)
            return Self.copy(draft, operationMode: mode, activeProfileID: id)
        }
    }

    /// Adds the macOS Services group, which allows Apple's own services to
    /// reach Apple's servers.
    @discardableResult
    func addMacOSServicesGroup() async throws -> ConfigurationMutationResult {
        try await mutateConfiguration(kind: "addBuiltInGroup") { draft in
            try PolicyDefinitionValidator.rejectCollision(
                BuiltInRuleGroups.macOSServicesName, existing: draft.localGroups.map { ($0.id, $0.name) }
            )
            let made = try BuiltInRuleGroups.macOSServices(lineageID: draft.lineageID, now: Date())
            return Self.copy(
                draft,
                enabledGroups: draft.enabledLocalGroupIDs.union([made.group.id]),
                rules: draft.rules + made.rules,
                groups: draft.localGroups + [made.group]
            )
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
                return deletingRules ? nil : try RuleMutation.removingGroup(
                    rule, groupWasOn: draft.enabledLocalGroupIDs.contains(id), now: now
                )
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
                return deletingRules ? nil : try RuleMutation.removingProfile(
                    rule, profileWasActive: draft.activeProfileID == id, now: now
                )
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
