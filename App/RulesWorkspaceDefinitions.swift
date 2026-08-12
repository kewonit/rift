import RiftCore
import Foundation

extension RulesWorkspaceController {
    func impact(for selection: RulesSidebarSelection) -> RuleDefinitionImpact {
        let assigned = allRules.filter { selection.includes($0) }
        return RuleDefinitionImpact(
            totalRules: assigned.count,
            protectedRules: assigned.count {
                $0.flags.contains(.protected) || $0.flags.contains(.sourceManaged)
            }
        )
    }

    func createProfile(name: String) async -> Bool {
        await definitionCommand("The profile was not created.") {
            try await controlPlane.createProfile(name: name)
        }
    }

    func updateProfile(
        _ id: UUID,
        name: String,
        operationModeOverride: OperationMode?
    ) async -> Bool {
        await definitionCommand("The profile was not changed.") {
            try await controlPlane.updateProfile(
                id,
                name: name,
                operationModeOverride: .some(operationModeOverride)
            )
        }
    }

    func activateProfile(_ id: UUID?) async {
        _ = await definitionCommand("The active profile was not changed.") {
            try await controlPlane.activateProfile(id)
        }
    }

    func removeProfile(_ id: UUID, deletingRules: Bool) async {
        _ = await definitionCommand(
            "The profile was not removed. Protected or managed rules were preserved."
        ) {
            try await controlPlane.removeProfile(id, deletingRules: deletingRules)
        }
    }

    func createGroup(name: String) async -> Bool {
        await definitionCommand("The group was not created.") {
            try await controlPlane.createLocalGroup(name: name)
        }
    }

    func updateGroup(_ id: UUID, name: String, note: String) async -> Bool {
        await definitionCommand("The group was not changed.") {
            try await controlPlane.updateLocalGroup(id, name: name, note: note)
        }
    }

    func setGroup(_ id: UUID, enabled: Bool) async {
        _ = await definitionCommand("The group state was not changed.") {
            try await controlPlane.setLocalGroup(id, enabled: enabled)
        }
    }

    func removeGroup(_ id: UUID, deletingRules: Bool) async {
        _ = await definitionCommand(
            "The group was not removed. Protected or managed rules were preserved."
        ) {
            try await controlPlane.removeLocalGroup(id, deletingRules: deletingRules)
        }
    }

    func setBlocklist(_ id: UUID, enabled: Bool) async {
        _ = await definitionCommand("The blocklist state was not changed.") {
            try await controlPlane.setBlocklist(id, enabled: enabled)
        }
    }

    func removeBlocklist(_ id: UUID) async {
        _ = await definitionCommand("The blocklist was not removed.") {
            try await controlPlane.removeBlocklist(id)
        }
    }

    func importBlocklist(data: Data, name: String) async -> Bool {
        await definitionCommand(
            "The blocklist was rejected; the active policy was not changed."
        ) {
            try await controlPlane.importBlocklist(data: data, name: name)
        }
    }
}

struct RuleDefinitionImpact: Equatable {
    let totalRules: Int
    let protectedRules: Int

    var eligibleRules: Int { totalRules - protectedRules }
}
