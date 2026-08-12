import AbyssControl
import Foundation

extension ControlPlaneController {
    func blocklistEntryImpact(_ value: String) async throws -> BlocklistEntryImpact {
        guard let configuration = try await repository?.currentConfiguration() else {
            throw RuleCommandError.missingConfiguration
        }
        return try BlocklistEntryOverrides.impact(
            for: BlocklistEntryOverrides.parseSingle(value),
            configuration: configuration
        )
    }

    @discardableResult
    func setBlocklistEntryOverride(
        _ entry: BlocklistEntry,
        disabled: Bool
    ) async throws -> ConfigurationMutationResult {
        try await mutateConfiguration(kind: disabled ? "disableBlocklistEntry" : "enableBlocklistEntry") {
            draft in
            _ = try BlocklistEntryOverrides.impact(for: entry, configuration: draft)
            var entries = draft.disabledBlocklistEntries
            let changed = disabled ? entries.insert(entry).inserted : entries.remove(entry) != nil
            guard changed else { throw BlocklistEntryOverrideError.unchanged }
            guard entries.count <= BlocklistEntryOverrides.maximumDisabledEntries else {
                throw BlocklistEntryOverrideError.tooManyDisabledEntries
            }
            return Self.copy(draft, disabledBlocklistEntries: entries)
        }
    }
}
