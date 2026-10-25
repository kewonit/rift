import RiftCore
import RiftIPC
import CryptoKit
import Foundation
import GRDB
import Testing
@testable import RiftControl

@Test func blocklistCompilerDeduplicatesMembershipAndAppliesGlobalDisable() throws {
    let lineageID = UUID()
    let now = Date(timeIntervalSince1970: 100)
    let shared = BlocklistEntry.domain(try DomainName("shared.example"))
    let first = try BlocklistImportBuilder.build(
        entries: [shared, .domain(try DomainName("first.example"))],
        name: "First", contentHash: Data(repeating: 1, count: 32),
        lineageID: lineageID, now: now
    )
    let second = try BlocklistImportBuilder.build(
        entries: [shared, .domain(try DomainName("second.example"))],
        name: "Second", contentHash: Data(repeating: 2, count: 32),
        lineageID: lineageID, now: now
    )
    let configuration = PolicyConfigurationDraft(
        lineageID: lineageID, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [],
        rules: first.rules + second.rules,
        blocklists: [first.source, second.source]
    )

    try PolicyConfigurationValidator.validate(configuration)
    let impact = try BlocklistEntryOverrides.impact(for: shared, configuration: configuration)
    #expect(impact.sourceNames == ["First", "Second"])
    #expect(impact.activeSourceNames == ["First", "Second"])
    #expect(!impact.isDisabled)
    #expect(try effectiveBlocklistEntries(configuration).count == 3)
    #expect(try effectiveBlocklistEntries(configuration).contains(shared))

    let disabled = copy(configuration, disabledEntries: [shared])
    try PolicyConfigurationValidator.validate(disabled)
    #expect(try !effectiveBlocklistEntries(disabled).contains(shared))
    #expect(try BlocklistEntryOverrides.impact(for: shared, configuration: disabled).isDisabled)

    let unknown = BlocklistEntry.domain(try DomainName("unknown.example"))
    #expect(throws: PolicyConfigurationValidationError.invalidRelationship) {
        try PolicyConfigurationValidator.validate(copy(configuration, disabledEntries: [unknown]))
    }
}

@Test func repositoryRetainsMembershipButPublishesDeduplicatedPolicy() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("rift-blocklist-overrides-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    let repository = PolicyRepository(database: database)
    let lineageID = UUID()
    let shared = BlocklistEntry.address(IPInterval(exact: try IPAddress("203.0.113.9")))
    let first = try BlocklistImportBuilder.build(
        entries: [shared], name: "One", contentHash: Data(repeating: 3, count: 32),
        lineageID: lineageID, now: Date(timeIntervalSince1970: 1)
    )
    let second = try BlocklistImportBuilder.build(
        entries: [shared], name: "Two", contentHash: Data(repeating: 4, count: 32),
        lineageID: lineageID, now: Date(timeIntervalSince1970: 2)
    )
    let draft = PolicyConfigurationDraft(
        lineageID: lineageID, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: first.rules + second.rules,
        blocklists: [first.source, second.source], disabledBlocklistEntries: [shared]
    )
    let desired = try await repository.save(
        draft, extensionHighWater: 0, expectedGeneration: 0,
        commandKind: "test", redactedSummary: "test", now: Date(timeIntervalSince1970: 3)
    )

    let stored = try #require(try await repository.currentConfiguration())
    #expect(stored.rules.count == 2)
    #expect(stored.disabledBlocklistEntries == [shared])
    #expect(try desired.artifact.decode().rules.isEmpty)
}

@Test func archiveVersionThreeRetainsOverridesAndVersionTwoDefaultsEmpty() throws {
    let lineageID = UUID()
    let entry = BlocklistEntry.domain(try DomainName("archive.example"))
    let list = try BlocklistImportBuilder.build(
        entries: [entry], name: "Archive", contentHash: Data(repeating: 5, count: 32),
        lineageID: lineageID, now: Date(timeIntervalSince1970: 10)
    )
    let draft = PolicyConfigurationDraft(
        lineageID: lineageID, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: list.rules,
        blocklists: [list.source], disabledBlocklistEntries: [entry]
    )
    let encoded = try ConfigurationArchiveCodec.export(
        draft: draft, appVersion: "test", now: Date(timeIntervalSince1970: 11)
    )
    #expect(try ConfigurationArchiveCodec.decode(encoded).disabledBlocklistEntries == [entry])

    let legacyPayload = LegacyArchivePayload(
        baseOperationMode: draft.baseOperationMode, activeProfileID: nil,
        rules: draft.rules, localGroups: [], profiles: [], blocklists: draft.blocklists
    )
    let encoder = CanonicalPolicyJSON.encoder()
    let legacy = LegacyArchive(
        schemaVersion: 2, appVersion: "1", exportedAt: Date(timeIntervalSince1970: 12),
        counts: ConfigurationArchiveCounts(rules: 1, localGroups: 0, profiles: 0, blocklists: 1),
        featureFlags: ["blocklists", "localGroups", "profiles", "reviewState"],
        payload: legacyPayload,
        checksum: Data(SHA256.hash(data: try encoder.encode(legacyPayload)))
    )
    #expect(try ConfigurationArchiveCodec.decode(
        encoder.encode(legacy)
    ).disabledBlocklistEntries.isEmpty)
}

@Test func oldConfigurationWithoutOverrideTableReadsAsEmpty() throws {
    let database = try DatabaseQueue()
    let entries = try database.read {
        try BlocklistOverrideStore.read($0, decoder: CanonicalPolicyJSON.decoder())
    }
    #expect(entries.isEmpty)
}

private func effectiveBlocklistEntries(
    _ configuration: PolicyConfigurationDraft
) throws -> Set<BlocklistEntry> {
    try BlocklistEntryOverrides.allEntries(
        in: BlocklistPolicyCompiler.effectiveRules(for: configuration)
    )
}

private func copy(
    _ configuration: PolicyConfigurationDraft,
    disabledEntries: Set<BlocklistEntry>
) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: configuration.lineageID, authorizedUID: configuration.authorizedUID,
        operationMode: configuration.operationMode,
        baseOperationMode: configuration.baseOperationMode,
        activeProfileID: configuration.activeProfileID,
        enabledLocalGroupIDs: configuration.enabledLocalGroupIDs,
        rules: configuration.rules, localGroups: configuration.localGroups,
        profiles: configuration.profiles, blocklists: configuration.blocklists,
        disabledBlocklistEntries: disabledEntries
    )
}

private struct LegacyArchivePayload: Codable {
    let baseOperationMode: OperationMode
    let activeProfileID: UUID?
    let rules: [Rule]
    let localGroups: [LocalRuleGroup]
    let profiles: [PolicyProfile]
    let blocklists: [BlocklistSource]
}

private struct LegacyArchive: Codable {
    let schemaVersion: UInt16
    let appVersion: String
    let exportedAt: Date
    let counts: ConfigurationArchiveCounts
    let featureFlags: [String]
    let payload: LegacyArchivePayload
    let checksum: Data
}
