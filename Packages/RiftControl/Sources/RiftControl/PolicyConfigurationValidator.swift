import RiftCore
import Foundation

public enum PolicyConfigurationValidationError: Error, Sendable, Equatable {
    case excessiveCount
    case duplicateIdentifier
    case duplicateName
    case invalidDefinition
    case invalidRelationship
    case invalidBlocklistRules
    case mismatchedLineage
    case inconsistentOperationMode
}

public enum PolicyConfigurationValidator {
    public static let maximumRules = 100_000
    public static let maximumDefinitions = 10_000
    public static let maximumEncodedRowBytes = 1 * 1_024 * 1_024

    public static func validate(_ draft: PolicyConfigurationDraft) throws {
        guard draft.rules.count <= maximumRules,
              draft.localGroups.count <= maximumDefinitions,
              draft.profiles.count <= maximumDefinitions,
              draft.blocklists.count <= maximumDefinitions,
              draft.enabledLocalGroupIDs.count <= maximumDefinitions,
              draft.disabledBlocklistEntries.count
                <= BlocklistEntryOverrides.maximumDisabledEntries else {
            throw PolicyConfigurationValidationError.excessiveCount
        }

        try requireUnique(draft.rules.map(\.id))
        try requireUnique(draft.localGroups.map(\.id))
        try requireUnique(draft.profiles.map(\.id))
        try requireUnique(draft.blocklists.map(\.id))
        try requireUniqueNames(draft.localGroups.map(\.name))
        try requireUniqueNames(draft.profiles.map(\.name))
        try requireUniqueNames(draft.blocklists.map(\.name))

        let groups = Set(draft.localGroups.map(\.id))
        let profiles = Set(draft.profiles.map(\.id))
        let blocklists = Set(draft.blocklists.map(\.id))
        guard draft.activeProfileID.map(profiles.contains) ?? true,
              draft.enabledLocalGroupIDs.isSubset(of: groups),
              draft.enabledLocalGroupIDs
                == Set(draft.localGroups.filter(\.isEnabled).map(\.id)) else {
            throw PolicyConfigurationValidationError.invalidRelationship
        }

        guard draft.baseOperationMode != .degradedFallback,
              draft.operationMode != .degradedFallback else {
            throw PolicyConfigurationValidationError.inconsistentOperationMode
        }
        let expectedMode = draft.profiles.first { $0.id == draft.activeProfileID }?
            .operationModeOverride ?? draft.baseOperationMode
        guard draft.operationMode == expectedMode else {
            throw PolicyConfigurationValidationError.inconsistentOperationMode
        }

        for rule in draft.rules {
            guard rule.lineageID == draft.lineageID else {
                throw PolicyConfigurationValidationError.mismatchedLineage
            }
            guard rule.profileID.map(profiles.contains) ?? true,
                  rule.localGroupID.map(groups.contains) ?? true else {
                throw PolicyConfigurationValidationError.invalidRelationship
            }
            if case .blocklist(let sourceID) = rule.source,
               !blocklists.contains(sourceID) {
                throw PolicyConfigurationValidationError.invalidRelationship
            }
            try rule.validateStoredRepresentation()
        }
        try validateBlocklistRules(rules: draft.rules, sources: draft.blocklists)
        let blocklistEntries = try BlocklistEntryOverrides.allEntries(in: draft.rules)
        guard draft.disabledBlocklistEntries.isSubset(of: blocklistEntries) else {
            throw PolicyConfigurationValidationError.invalidRelationship
        }

        guard draft.localGroups.allSatisfy({ group in
            isCanonicalName(group.name)
                && group.note.unicodeScalars.count <= PolicyLimits.maximumNotesScalars
        }), draft.profiles.allSatisfy({ profile in
            isCanonicalName(profile.name)
                && (profile.symbolName?.unicodeScalars.count ?? 0) <= 64
                && profile.operationModeOverride != .degradedFallback
        }), draft.blocklists.allSatisfy({ isCanonicalName($0.name) }) else {
            throw PolicyConfigurationValidationError.invalidDefinition
        }
    }

    public static func validateBlocklistRules(
        rules: [Rule],
        sources: [BlocklistSource]
    ) throws {
        try BlocklistRuleInvariant.validate(rules: rules, sources: sources)
    }

    private static func requireUnique(_ values: [UUID]) throws {
        guard Set(values).count == values.count else {
            throw PolicyConfigurationValidationError.duplicateIdentifier
        }
    }

    private static func requireUniqueNames(_ values: [String]) throws {
        let locale = Locale(identifier: "en_US_POSIX")
        let keys = values.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        }
        guard Set(keys).count == keys.count else {
            throw PolicyConfigurationValidationError.duplicateName
        }
    }

    private static func isCanonicalName(_ value: String) -> Bool {
        guard let validated = try? PolicyDefinitionValidator.name(value) else { return false }
        return validated == value
    }
}
