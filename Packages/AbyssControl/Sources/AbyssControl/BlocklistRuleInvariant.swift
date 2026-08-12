import AbyssCore
import Foundation

enum BlocklistRuleInvariant {
    static func validate(rules: [Rule], sources: [BlocklistSource]) throws {
        let sourceIDs = Set(sources.map(\.id))
        guard sourceIDs.count == sources.count else { throw invalid }

        var rulesBySource: [UUID: [Rule]] = [:]
        for rule in rules {
            if case .blocklist(let sourceID) = rule.source {
                guard sourceIDs.contains(sourceID) else { throw invalid }
                rulesBySource[sourceID, default: []].append(rule)
            } else if rule.flags.contains(.sourceManaged) {
                throw invalid
            }
        }

        for source in sources {
            guard let rules = rulesBySource[source.id], !rules.isEmpty else { throw invalid }
            try validate(source: source, rules: rules)
        }
    }

    static func isUniversal(_ interval: IPInterval) -> Bool {
        interval.lowerBound.bytes.allSatisfy { $0 == 0 }
            && interval.upperBound.bytes.allSatisfy { $0 == UInt8.max }
    }

    private static func validate(source: BlocklistSource, rules: [Rule]) throws {
        guard source.entryCount > 0,
              source.entryCount <= BlocklistParser.maximumEntries,
              let domainCount = source.domainEntryCount,
              let addressCount = source.addressEntryCount,
              domainCount >= 0,
              addressCount >= 0,
              domainCount <= source.entryCount,
              addressCount == source.entryCount - domainCount,
              source.contentHash.count == 32,
              source.importedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw invalid
        }
        guard rules.count == chunkCount(domainCount) + chunkCount(addressCount) else {
            throw invalid
        }

        let reference = rules[0]
        guard reference.revision > 0,
              reference.createdAt == source.importedAt,
              reference.modifiedAt >= reference.createdAt,
              reference.modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw invalid
        }

        var domains: Set<DomainName> = []
        var addresses: Set<IPInterval> = []
        var domainChunks: [[DomainName]] = []
        var addressChunks: [[IPInterval]] = []
        for rule in rules {
            guard hasCanonicalShape(rule, source: source),
                  rule.lineageID == reference.lineageID,
                  rule.revision == reference.revision,
                  rule.createdAt == reference.createdAt,
                  rule.modifiedAt == reference.modifiedAt else {
                throw invalid
            }
            switch rule.destination {
            case .exactHostnameSet(let values):
                guard values.count <= domainCount - domains.count,
                      values.allSatisfy({ domains.insert($0).inserted }) else {
                    throw invalid
                }
                domainChunks.append(values)
            case .ipSet(let values):
                guard values.count <= addressCount - addresses.count,
                      !values.contains(where: isUniversal),
                      values.allSatisfy({ addresses.insert($0).inserted }) else {
                    throw invalid
                }
                addressChunks.append(values)
            case .domainSet, .endpointClass, .anyEndpoint:
                throw invalid
            }
        }

        guard domains.count == domainCount,
              addresses.count == addressCount,
              canonicalChunks(Array(domains).sorted()) == sortedChunks(domainChunks),
              canonicalChunks(Array(addresses).sorted()) == sortedChunks(addressChunks) else {
            throw invalid
        }
    }

    private static func hasCanonicalShape(_ rule: Rule, source: BlocklistSource) -> Bool {
        rule.action == .filter(.deny)
            && rule.priority == .blocklistDeny
            && rule.process == .anyProcess
            && rule.transportProtocol == .anySupportedProtocol
            && rule.port == nil
            && rule.direction == .bidirectional
            && rule.owner == .authorizedUser
            && rule.profileID == nil
            && rule.localGroupID == nil
            && rule.expiresAt == nil
            && rule.flags == [.sourceManaged]
            && rule.reviewState == .reviewed
            && rule.notes.isEmpty
            && rule.isEnabled == (source.status == .active)
    }

    private static func canonicalChunks<Value: Comparable>(_ values: [Value]) -> [[Value]] {
        stride(from: 0, to: values.count, by: PolicyLimits.maximumDestinationMembers).map { start in
            Array(values[start..<min(start + PolicyLimits.maximumDestinationMembers, values.count)])
        }
    }

    private static func chunkCount(_ memberCount: Int) -> Int {
        guard memberCount > 0 else { return 0 }
        return (memberCount + PolicyLimits.maximumDestinationMembers - 1)
            / PolicyLimits.maximumDestinationMembers
    }

    private static func sortedChunks<Value: Comparable>(_ chunks: [[Value]]) -> [[Value]] {
        chunks.sorted { $0.lexicographicallyPrecedes($1) }
    }

    private static var invalid: PolicyConfigurationValidationError { .invalidBlocklistRules }
}
