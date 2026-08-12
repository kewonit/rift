import AbyssCore
import Foundation

public struct BlocklistImportResult: Sendable, Hashable {
    public let source: BlocklistSource
    public let rules: [Rule]
}

public struct BlocklistImportPreparation: Sendable {
    public let name: String
    fileprivate let contentHash: Data
    fileprivate let domains: [DomainName]
    fileprivate let addresses: [IPInterval]
}

public enum BlocklistImportError: Error, Sendable, Equatable {
    case emptyName
    case invalidHash
    case tooManyEntries
    case universalAddressRange(IPAddress.Family)
}

public enum BlocklistImportBuilder {
    public static func build(
        entries: [BlocklistEntry],
        name: String,
        contentHash: Data,
        lineageID: UUID,
        now: Date
    ) throws -> BlocklistImportResult {
        try build(
            preparation: prepare(entries: entries, name: name, contentHash: contentHash),
            lineageID: lineageID,
            now: now
        )
    }

    public static func build(
        preparation: BlocklistImportPreparation,
        lineageID: UUID,
        now: Date
    ) throws -> BlocklistImportResult {
        try Task.checkCancellation()
        let sourceID = UUID()
        var rules: [Rule] = []
        for start in stride(
            from: 0, to: preparation.domains.count,
            by: PolicyLimits.maximumDestinationMembers
        ) {
            try Task.checkCancellation()
            let end = min(
                start + PolicyLimits.maximumDestinationMembers, preparation.domains.count
            )
            rules.append(try rule(
                sourceID: sourceID,
                lineageID: lineageID,
                destination: .normalizedExactHostnameSet(Array(preparation.domains[start..<end])),
                now: now
            ))
        }
        for start in stride(
            from: 0, to: preparation.addresses.count,
            by: PolicyLimits.maximumDestinationMembers
        ) {
            try Task.checkCancellation()
            let end = min(
                start + PolicyLimits.maximumDestinationMembers, preparation.addresses.count
            )
            rules.append(try rule(
                sourceID: sourceID,
                lineageID: lineageID,
                destination: .normalizedIPSet(Array(preparation.addresses[start..<end])),
                now: now
            ))
        }
        return BlocklistImportResult(
            source: BlocklistSource(
                id: sourceID,
                name: preparation.name,
                importedAt: now,
                entryCount: preparation.domains.count + preparation.addresses.count,
                domainEntryCount: preparation.domains.count,
                addressEntryCount: preparation.addresses.count,
                contentHash: preparation.contentHash,
                status: .active
            ),
            rules: rules
        )
    }

    static func prepare(
        entries: [BlocklistEntry],
        name: String,
        contentHash: Data
    ) throws -> BlocklistImportPreparation {
        let trimmedName = try PolicyDefinitionValidator.name(name)
        guard contentHash.count == 32 else { throw BlocklistImportError.invalidHash }
        var domains: Set<DomainName> = []
        var addresses: Set<IPInterval> = []
        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 1_024) { try Task.checkCancellation() }
            switch entry {
            case .domain(let value): domains.insert(value)
            case .address(let value): addresses.insert(value)
            }
            guard domains.count + addresses.count <= BlocklistParser.maximumEntries else {
                throw BlocklistImportError.tooManyEntries
            }
        }
        if let universal = addresses.first(where: BlocklistRuleInvariant.isUniversal) {
            throw BlocklistImportError.universalAddressRange(universal.lowerBound.family)
        }
        return BlocklistImportPreparation(
            name: trimmedName,
            contentHash: contentHash,
            domains: domains.sorted(),
            addresses: addresses.sorted()
        )
    }

    private static func rule(
        sourceID: UUID,
        lineageID: UUID,
        destination: DestinationCondition,
        now: Date
    ) throws -> Rule {
        try Rule(
            id: UUID(),
            lineageID: lineageID,
            revision: 1,
            action: .filter(.deny),
            priority: .blocklistDeny,
            process: .anyProcess,
            destination: destination,
            transportProtocol: .anySupportedProtocol,
            port: nil,
            direction: .bidirectional,
            owner: .authorizedUser,
            isEnabled: true,
            flags: [.sourceManaged],
            reviewState: .reviewed,
            source: .blocklist(sourceID: sourceID),
            notes: "",
            createdAt: now,
            modifiedAt: now
        )
    }
}
