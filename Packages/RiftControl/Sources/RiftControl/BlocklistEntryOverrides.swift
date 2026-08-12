import RiftCore
import Foundation

public struct BlocklistEntryImpact: Sendable, Hashable {
    public let entry: BlocklistEntry
    public let sourceNames: [String]
    public let activeSourceNames: [String]
    public let isDisabled: Bool

    public init(
        entry: BlocklistEntry,
        sourceNames: [String],
        activeSourceNames: [String],
        isDisabled: Bool
    ) {
        self.entry = entry
        self.sourceNames = sourceNames
        self.activeSourceNames = activeSourceNames
        self.isDisabled = isDisabled
    }
}

public enum BlocklistEntryOverrideError: Error, Sendable, Equatable {
    case requiresSingleEntry
    case unknownEntry
    case tooManyDisabledEntries
    case invalidManagedRule
    case unchanged
}

public enum BlocklistEntryOverrides {
    public static let maximumDisabledEntries = 10_000

    public static func parseSingle(_ value: String) throws -> BlocklistEntry {
        let entries = try BlocklistParser.parse(Data(value.utf8))
        guard entries.count == 1, let entry = entries.first else {
            throw BlocklistEntryOverrideError.requiresSingleEntry
        }
        return entry
    }

    public static func impact(
        for entry: BlocklistEntry,
        configuration: PolicyConfigurationDraft
    ) throws -> BlocklistEntryImpact {
        let sourceIDs = try membershipSourceIDs(for: entry, rules: configuration.rules)
        guard !sourceIDs.isEmpty else { throw BlocklistEntryOverrideError.unknownEntry }
        let sources = configuration.blocklists.filter { sourceIDs.contains($0.id) }
        let sorter: (BlocklistSource, BlocklistSource) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return BlocklistEntryImpact(
            entry: entry,
            sourceNames: sources.sorted(by: sorter).map(\.name),
            activeSourceNames: sources.filter { $0.status == .active }.sorted(by: sorter).map(\.name),
            isDisabled: configuration.disabledBlocklistEntries.contains(entry)
        )
    }

    public static func retainingKnownEntries(
        _ disabled: Set<BlocklistEntry>,
        in rules: [Rule]
    ) throws -> Set<BlocklistEntry> {
        disabled.intersection(try allEntries(in: rules))
    }

    static func allEntries(in rules: [Rule]) throws -> Set<BlocklistEntry> {
        var result: Set<BlocklistEntry> = []
        for rule in rules where rule.blocklistSourceID != nil {
            guard let entries = entries(in: rule) else {
                throw BlocklistEntryOverrideError.invalidManagedRule
            }
            result.formUnion(entries)
        }
        return result
    }

    static func membershipSourceIDs(
        for entry: BlocklistEntry,
        rules: [Rule]
    ) throws -> Set<UUID> {
        var result: Set<UUID> = []
        for rule in rules {
            guard let sourceID = rule.blocklistSourceID else { continue }
            guard let entries = entries(in: rule) else {
                throw BlocklistEntryOverrideError.invalidManagedRule
            }
            if entries.contains(entry) { result.insert(sourceID) }
        }
        return result
    }

    static func entries(in rule: Rule) -> [BlocklistEntry]? {
        switch rule.destination {
        case .exactHostnameSet(let values): values.map(BlocklistEntry.domain)
        case .ipSet(let values): values.map(BlocklistEntry.address)
        case .domainSet, .endpointClass, .anyEndpoint: nil
        }
    }
}

enum BlocklistPolicyCompiler {
    static func effectiveRules(for draft: PolicyConfigurationDraft) throws -> [Rule] {
        var result = draft.rules.filter { $0.blocklistSourceID == nil }
        var emittedEntries: Set<BlocklistEntry> = []
        let activeSourceIDs = Set(draft.blocklists.lazy
            .filter { $0.status == .active }
            .map(\.id))
        let managed = draft.rules.filter { $0.blocklistSourceID != nil }.sorted {
            let leftSource = $0.blocklistSourceID?.uuidString ?? ""
            let rightSource = $1.blocklistSourceID?.uuidString ?? ""
            return leftSource == rightSource
                ? $0.id.uuidString < $1.id.uuidString
                : leftSource < rightSource
        }
        for rule in managed {
            guard let sourceID = rule.blocklistSourceID,
                  activeSourceIDs.contains(sourceID) else { continue }
            guard let entries = BlocklistEntryOverrides.entries(in: rule) else {
                throw BlocklistEntryOverrideError.invalidManagedRule
            }
            let retained = entries.filter {
                !draft.disabledBlocklistEntries.contains($0)
                    && emittedEntries.insert($0).inserted
            }
            guard !retained.isEmpty else { continue }
            result.append(try rule.replacingBlocklistEntries(retained))
        }
        return result
    }
}

private extension Rule {
    var blocklistSourceID: UUID? {
        guard case .blocklist(let sourceID) = source else { return nil }
        return sourceID
    }

    func replacingBlocklistEntries(_ entries: [BlocklistEntry]) throws -> Rule {
        let destination: DestinationCondition
        switch entries.first {
        case .domain:
            let values = entries.compactMap { entry -> DomainName? in
                guard case .domain(let value) = entry else { return nil }
                return value
            }
            guard values.count == entries.count else {
                throw BlocklistEntryOverrideError.invalidManagedRule
            }
            destination = try .normalizedExactHostnameSet(values)
        case .address:
            let values = entries.compactMap { entry -> IPInterval? in
                guard case .address(let value) = entry else { return nil }
                return value
            }
            guard values.count == entries.count else {
                throw BlocklistEntryOverrideError.invalidManagedRule
            }
            destination = try .normalizedIPSet(values)
        case nil:
            throw BlocklistEntryOverrideError.invalidManagedRule
        }
        return try Rule(
            id: id, lineageID: lineageID, revision: revision,
            action: action, priority: priority, process: process,
            destination: destination, transportProtocol: transportProtocol,
            port: port, direction: direction, owner: owner,
            profileID: profileID, localGroupID: localGroupID,
            expiresAt: expiresAt, isEnabled: isEnabled, flags: flags,
            reviewState: reviewState, source: source, notes: notes,
            createdAt: createdAt, modifiedAt: modifiedAt
        )
    }
}
