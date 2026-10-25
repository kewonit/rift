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
        await definitionCommand("Couldn’t create the profile.") {
            try await controlPlane.createProfile(name: name)
        }
    }

    func updateProfile(
        _ id: UUID,
        name: String,
        operationModeOverride: OperationMode?
    ) async -> Bool {
        await definitionCommand("Couldn’t change the profile.") {
            try await controlPlane.updateProfile(
                id,
                name: name,
                operationModeOverride: .some(operationModeOverride)
            )
        }
    }

    func activateProfile(_ id: UUID?) async {
        _ = await definitionCommand("Couldn’t switch profiles. Try again.") {
            try await controlPlane.activateProfile(id)
        }
    }

    func removeProfile(_ id: UUID, deletingRules: Bool) async {
        _ = await definitionCommand(
            "Couldn’t remove the profile. It may contain protected or blocklist rules."
        ) {
            try await controlPlane.removeProfile(id, deletingRules: deletingRules)
        }
    }

    func createGroup(name: String) async -> Bool {
        await definitionCommand("Couldn’t create the group.") {
            try await controlPlane.createLocalGroup(name: name)
        }
    }

    func updateGroup(_ id: UUID, name: String, note: String) async -> Bool {
        await definitionCommand("Couldn’t change the group.") {
            try await controlPlane.updateLocalGroup(id, name: name, note: note)
        }
    }

    func setGroup(_ id: UUID, enabled: Bool) async {
        _ = await definitionCommand("Couldn’t turn the group on or off.") {
            try await controlPlane.setLocalGroup(id, enabled: enabled)
        }
    }

    func removeGroup(_ id: UUID, deletingRules: Bool) async {
        _ = await definitionCommand(
            "Couldn’t remove the group. It may contain protected or blocklist rules."
        ) {
            try await controlPlane.removeLocalGroup(id, deletingRules: deletingRules)
        }
    }

    func setBlocklist(_ id: UUID, enabled: Bool) async {
        _ = await definitionCommand("Couldn’t turn the blocklist on or off.") {
            try await controlPlane.setBlocklist(id, enabled: enabled)
        }
    }

    func removeBlocklist(_ id: UUID) async {
        _ = await definitionCommand("Couldn’t remove the blocklist.") {
            try await controlPlane.removeBlocklist(id)
        }
    }

    func importBlocklist(data: Data, name: String) async -> Bool {
        await definitionCommand(
            "Couldn’t import the blocklist. Your rules haven’t changed."
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
