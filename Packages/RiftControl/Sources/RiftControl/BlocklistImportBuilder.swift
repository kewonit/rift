import RiftCore
import Foundation

public struct BlocklistImportResult: Sendable, Hashable {
    public let source: BlocklistSource
    public let rules: [Rule]
}

public struct BlocklistImportPreparation: Sendable {
    public let name: String
    public let contentHash: Data
    fileprivate let domains: [DomainName]
    /// Names blocked with every name under them.
    fileprivate let subdomainDomains: [DomainName]
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
        now: Date,
        suffixes: PublicSuffixList = .shared
    ) throws -> BlocklistImportResult {
        try build(
            preparation: prepare(entries: entries, name: name, contentHash: contentHash, suffixes: suffixes),
            lineageID: lineageID,
            now: now
        )
    }

    /// Pass the `sourceID` and `status` of a blocklist to build its update.
    public static func build(
        preparation: BlocklistImportPreparation,
        lineageID: UUID,
        now: Date,
        sourceID: UUID = UUID(),
        status: BlocklistSourceStatus = .active
    ) throws -> BlocklistImportResult {
        try Task.checkCancellation()
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
                enabled: status == .active,
                now: now
            ))
        }
        for start in stride(
            from: 0, to: preparation.subdomainDomains.count,
            by: PolicyLimits.maximumDestinationMembers
        ) {
            try Task.checkCancellation()
            let end = min(
                start + PolicyLimits.maximumDestinationMembers, preparation.subdomainDomains.count
            )
            rules.append(try rule(
                sourceID: sourceID,
                lineageID: lineageID,
                destination: .normalizedDomainSet(Array(preparation.subdomainDomains[start..<end])),
                enabled: status == .active,
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
                enabled: status == .active,
                now: now
            ))
        }
        return BlocklistImportResult(
            source: BlocklistSource(
                id: sourceID,
                name: preparation.name,
                importedAt: now,
                entryCount: preparation.domains.count + preparation.subdomainDomains.count
                    + preparation.addresses.count,
                domainEntryCount: preparation.domains.count + preparation.subdomainDomains.count,
                addressEntryCount: preparation.addresses.count,
                contentHash: preparation.contentHash,
                status: status
            ),
            rules: rules
        )
    }

    /// Sorts entries into exact names, names with their subdomains, and
    /// addresses. A name that would cover a whole registry, like `co.uk`, is
    /// kept exact, and so is every name when the suffix list is unavailable.
    static func prepare(
        entries: [BlocklistEntry],
        name: String,
        contentHash: Data,
        suffixes: PublicSuffixList = .shared
    ) throws -> BlocklistImportPreparation {
        let trimmedName = try PolicyDefinitionValidator.name(name)
        guard contentHash.count == 32 else { throw BlocklistImportError.invalidHash }
        var domains: Set<DomainName> = []
        var subdomainDomains: Set<DomainName> = []
        var addresses: Set<IPInterval> = []
        for (offset, entry) in entries.enumerated() {
            if offset.isMultiple(of: 1_024) { try Task.checkCancellation() }
            switch entry {
            case .domain(let value): domains.insert(value)
            case .address(let value): addresses.insert(value)
            case .domainAndSubdomains(let value):
                if suffixes.coversWholeRegistry(value) {
                    domains.insert(value)
                } else {
                    subdomainDomains.insert(value)
                }
            }
            guard domains.count + subdomainDomains.count + addresses.count
                <= BlocklistParser.maximumEntries else {
                throw BlocklistImportError.tooManyEntries
            }
        }
        // A name listed both ways is already covered with its subdomains.
        domains.subtract(subdomainDomains)
        if let universal = addresses.first(where: BlocklistRuleInvariant.isUniversal) {
            throw BlocklistImportError.universalAddressRange(universal.lowerBound.family)
        }
        return BlocklistImportPreparation(
            name: trimmedName,
            contentHash: contentHash,
            domains: domains.sorted(),
            subdomainDomains: subdomainDomains.sorted(),
            addresses: addresses.sorted()
        )
    }

    private static func rule(
        sourceID: UUID,
        lineageID: UUID,
        destination: DestinationCondition,
        enabled: Bool,
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
            isEnabled: enabled,
            flags: [.sourceManaged],
            reviewState: .reviewed,
            source: .blocklist(sourceID: sourceID),
            notes: "",
            createdAt: now,
            modifiedAt: now
        )
    }
}
