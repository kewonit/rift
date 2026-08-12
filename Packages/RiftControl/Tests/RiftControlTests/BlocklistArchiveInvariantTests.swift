import RiftCore
import CryptoKit
import Foundation
import GRDB
import Testing
@testable import RiftControl

@Test func checksumValidArchiveRejectsNoncanonicalBlocklistShapes() throws {
    let valid = try canonicalDraft(domainCount: 257)
    let source = try #require(valid.blocklists.first)
    let first = try #require(valid.rules.first)
    let second = try #require(valid.rules.dropFirst().first)
    guard case .exactHostnameSet(let firstValues) = first.destination,
          case .exactHostnameSet(let secondValues) = second.destination else {
        Issue.record("Expected two exact-hostname chunks")
        return
    }
    let moved = try #require(firstValues.last)
    let rechunked = [
        try copy(first, destination: .normalizedExactHostnameSet(Array(firstValues.dropLast()))),
        try copy(second, destination: .normalizedExactHostnameSet([moved] + secondValues)),
    ]
    let duplicate = try copy(first, id: UUID())
    let attacks = [
        draft(valid, rules: rechunked),
        draft(valid, sources: [copyWithoutCounts(source)]),
        draft(valid, sources: [copy(source, contentHash: Data(repeating: 1, count: 31))]),
        draft(valid, sources: [copy(
            source,
            domainCount: Int.max,
            addressCount: Int.max
        )]),
        draft(valid, sources: [copy(
            source,
            importedAt: source.importedAt.addingTimeInterval(1)
        )]),
        draft(valid, sources: [copy(source, status: .disabled)]),
        draft(
            valid,
            rules: valid.rules + [duplicate],
            sources: [copy(source, entryCount: 513, domainCount: 513, addressCount: 0)]
        ),
        draft(
            valid,
            sources: [copy(source, entryCount: 258, domainCount: 258, addressCount: 0)]
        ),
    ]

    for attack in attacks {
        let bytes = try checksumValidArchive(for: attack)
        #expect(throws: ConfigurationArchiveError.invalidDefinition) {
            try ConfigurationArchiveCodec.decode(bytes)
        }
    }
}

@Test func checksumValidArchiveRejectsUniversalManagedRanges() throws {
    let lineageID = UUID()
    let sourceID = UUID()
    let now = Date(timeIntervalSince1970: 10)
    let universal = try IPInterval(cidr: IPAddress("0.0.0.0"), prefixLength: 0)
    let rule = try Rule(
        id: UUID(), lineageID: lineageID, revision: 1,
        action: .filter(.deny), priority: .blocklistDeny,
        process: .anyProcess, destination: .normalizedIPSet([universal]),
        transportProtocol: .anySupportedProtocol, port: nil,
        direction: .bidirectional, owner: .authorizedUser,
        isEnabled: true, flags: [.sourceManaged], reviewState: .reviewed,
        source: .blocklist(sourceID: sourceID), createdAt: now, modifiedAt: now
    )
    let source = BlocklistSource(
        id: sourceID, name: "Universal", importedAt: now,
        entryCount: 1, domainEntryCount: 0, addressEntryCount: 1,
        contentHash: Data(repeating: 2, count: 32), status: .active
    )
    let draft = PolicyConfigurationDraft(
        lineageID: lineageID, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: [rule],
        blocklists: [source]
    )

    #expect(throws: ConfigurationArchiveError.invalidDefinition) {
        try ConfigurationArchiveCodec.decode(checksumValidArchive(for: draft))
    }
}

@Test func canonicalDisabledSourceRetainsValidManagedProvenance() throws {
    let valid = try canonicalDraft(domainCount: 257)
    let source = try #require(valid.blocklists.first)
    let modifiedAt = Date(timeIntervalSince1970: 20)
    let rules = try valid.rules.map {
        try RuleMutation.managedEnabled($0, value: false, now: modifiedAt)
    }
    let disabled = copy(source, status: .disabled)
    let candidate = draft(valid, rules: rules, sources: [disabled])

    try PolicyConfigurationValidator.validate(candidate)
    #expect(try ConfigurationArchiveCodec.decode(
        ConfigurationArchiveCodec.export(
            draft: candidate, appVersion: "test", now: modifiedAt
        )
    ).rules == rules)
}

@Test func hostileArchiveIsRejectedBeforeRepositoryGenerationMutation() async throws {
    let context = try ArchiveInvariantContext()
    defer { context.remove() }
    let original = try await context.repository.save(
        context.emptyDraft(), extensionHighWater: 0, expectedGeneration: 0,
        commandKind: "initial", redactedSummary: "initial",
        now: Date(timeIntervalSince1970: 1)
    )
    let valid = try canonicalDraft(domainCount: 1, lineageID: context.lineageID)
    let source = try #require(valid.blocklists.first)
    let hostile = draft(
        valid,
        sources: [copyWithoutCounts(source)]
    )

    do {
        let payload = try ConfigurationArchiveCodec.decode(checksumValidArchive(for: hostile))
        let candidate = PolicyConfigurationDraft(
            lineageID: context.lineageID, authorizedUID: 501,
            operationMode: payload.baseOperationMode,
            activeProfileID: payload.activeProfileID,
            enabledLocalGroupIDs: Set(payload.localGroups.filter(\.isEnabled).map(\.id)),
            rules: payload.rules, localGroups: payload.localGroups,
            profiles: payload.profiles, blocklists: payload.blocklists
        )
        _ = try await context.repository.save(
            candidate, extensionHighWater: 0,
            expectedGeneration: original.tuple.generation,
            commandKind: "restore", redactedSummary: "restore", now: Date()
        )
        Issue.record("Hostile archive unexpectedly reached repository mutation")
    } catch ConfigurationArchiveError.invalidDefinition {
        // Expected: archive validation precedes desired-policy/root publication.
    }

    #expect(try await context.repository.newestDesiredPolicy()?.tuple == original.tuple)
    let counts = try await context.writeCounts()
    #expect(counts.outbox == 1)
    #expect(counts.audit == 1)
}

@Test func repositorySaveAndReadApplyTheSameBlocklistInvariant() async throws {
    let context = try ArchiveInvariantContext()
    defer { context.remove() }
    let valid = try canonicalDraft(domainCount: 257, lineageID: context.lineageID)
    let source = try #require(valid.blocklists.first)
    let first = try #require(valid.rules.first)
    let second = try #require(valid.rules.dropFirst().first)
    guard case .exactHostnameSet(let firstValues) = first.destination,
          case .exactHostnameSet(let secondValues) = second.destination else {
        Issue.record("Expected two exact-hostname chunks")
        return
    }
    let moved = try #require(firstValues.last)
    let forgedRules = [
        try copy(first, destination: .normalizedExactHostnameSet(Array(firstValues.dropLast()))),
        try copy(second, destination: .normalizedExactHostnameSet([moved] + secondValues)),
    ]
    let forged = draft(valid, rules: forgedRules)

    await #expect(throws: PolicyConfigurationValidationError.invalidBlocklistRules) {
        try await context.repository.save(
            forged, extensionHighWater: 0, expectedGeneration: 0,
            commandKind: "forged", redactedSummary: "forged", now: Date()
        )
    }
    #expect(try await context.repository.newestDesiredPolicy() == nil)

    let saved = try await context.repository.save(
        valid, extensionHighWater: 0, expectedGeneration: 0,
        commandKind: "valid", redactedSummary: "valid", now: Date()
    )
    #expect(try await context.repository.currentConfiguration()?.rules.count == 2)
    let missingCounts = copyWithoutCounts(source)
    let encoded = try CanonicalPolicyJSON.encoder().encode(missingCounts)
    try await context.database.write { database in
        try database.execute(
            sql: "UPDATE blocklist_sources SET encoded_value = ? WHERE id = ?",
            arguments: [encoded, source.id.uuidString.lowercased()]
        )
    }

    await #expect(throws: PolicyConfigurationValidationError.invalidBlocklistRules) {
        try await context.repository.currentConfiguration()
    }
    #expect(try await context.repository.newestDesiredPolicy()?.tuple == saved.tuple)
}

private struct ArchiveInvariantContext {
    let directory: URL
    let database: DatabasePool
    let repository: PolicyRepository
    let lineageID = UUID()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rift-blocklist-invariant-\(UUID().uuidString)")
        database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
        repository = PolicyRepository(database: database)
    }

    func emptyDraft() -> PolicyConfigurationDraft {
        PolicyConfigurationDraft(
            lineageID: lineageID, authorizedUID: 501, operationMode: .silentAllow,
            activeProfileID: nil, enabledLocalGroupIDs: [], rules: []
        )
    }

    func writeCounts() async throws -> (outbox: Int, audit: Int) {
        try await database.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM policy_outbox") ?? 0,
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM command_audit") ?? 0
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func canonicalDraft(
    domainCount: Int,
    lineageID: UUID = UUID()
) throws -> PolicyConfigurationDraft {
    let entries = try (0..<domainCount).reversed().flatMap { index in
        let entry = BlocklistEntry.domain(try DomainName(String(format: "host%06d.example", index)))
        return index == 0 ? [entry, entry] : [entry]
    }
    let result = try BlocklistImportBuilder.build(
        entries: entries, name: "Canonical",
        contentHash: Data(SHA256.hash(data: Data("fixture".utf8))),
        lineageID: lineageID, now: Date(timeIntervalSince1970: 10)
    )
    return PolicyConfigurationDraft(
        lineageID: lineageID, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: result.rules,
        blocklists: [result.source]
    )
}

private func checksumValidArchive(for draft: PolicyConfigurationDraft) throws -> Data {
    let payload = ConfigurationArchivePayload(
        baseOperationMode: draft.baseOperationMode,
        activeProfileID: draft.activeProfileID,
        rules: draft.rules,
        localGroups: draft.localGroups,
        profiles: draft.profiles,
        blocklists: draft.blocklists
    )
    let encoder = CanonicalPolicyJSON.encoder()
    let checksum = Data(SHA256.hash(data: try encoder.encode(payload)))
    return try encoder.encode(ConfigurationArchive(
        schemaVersion: ConfigurationArchive.schemaVersion,
        appVersion: "hostile-fixture",
        exportedAt: Date(timeIntervalSince1970: 20),
        counts: ConfigurationArchiveCounts(
            rules: payload.rules.count,
            localGroups: payload.localGroups.count,
            profiles: payload.profiles.count,
            blocklists: payload.blocklists.count
        ),
        featureFlags: [
            "blocklistEntryOverrides", "blocklists", "localGroups", "profiles", "reviewState",
        ],
        payload: payload,
        checksum: checksum
    ))
}

private func draft(
    _ draft: PolicyConfigurationDraft,
    rules: [Rule]? = nil,
    sources: [BlocklistSource]? = nil
) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: draft.lineageID, authorizedUID: draft.authorizedUID,
        operationMode: draft.operationMode, baseOperationMode: draft.baseOperationMode,
        activeProfileID: draft.activeProfileID,
        enabledLocalGroupIDs: draft.enabledLocalGroupIDs,
        rules: rules ?? draft.rules, localGroups: draft.localGroups,
        profiles: draft.profiles, blocklists: sources ?? draft.blocklists
    )
}

private func copy(
    _ source: BlocklistSource,
    importedAt: Date? = nil,
    entryCount: Int? = nil,
    domainCount: Int? = nil,
    addressCount: Int? = nil,
    contentHash: Data? = nil,
    status: BlocklistSourceStatus? = nil
) -> BlocklistSource {
    BlocklistSource(
        id: source.id, name: source.name, importedAt: importedAt ?? source.importedAt,
        entryCount: entryCount ?? source.entryCount,
        domainEntryCount: domainCount ?? source.domainEntryCount,
        addressEntryCount: addressCount ?? source.addressEntryCount,
        contentHash: contentHash ?? source.contentHash, status: status ?? source.status
    )
}

private func copyWithoutCounts(_ source: BlocklistSource) -> BlocklistSource {
    BlocklistSource(
        id: source.id, name: source.name, importedAt: source.importedAt,
        entryCount: source.entryCount, domainEntryCount: nil, addressEntryCount: nil,
        contentHash: source.contentHash, status: source.status
    )
}

private func copy(
    _ rule: Rule,
    id: UUID? = nil,
    destination: DestinationCondition? = nil
) throws -> Rule {
    try Rule(
        id: id ?? rule.id, lineageID: rule.lineageID, revision: rule.revision,
        action: rule.action, priority: rule.priority, process: rule.process,
        destination: destination ?? rule.destination,
        transportProtocol: rule.transportProtocol, port: rule.port,
        direction: rule.direction, owner: rule.owner,
        profileID: rule.profileID, localGroupID: rule.localGroupID,
        expiresAt: rule.expiresAt, isEnabled: rule.isEnabled, flags: rule.flags,
        reviewState: rule.reviewState, source: rule.source, notes: rule.notes,
        createdAt: rule.createdAt, modifiedAt: rule.modifiedAt
    )
}
