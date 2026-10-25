import RiftControl
import RiftCore
import CryptoKit
import Foundation
import Testing

@Test func validBlocklistConfigurationAndArchivePassCanonicalValidation() throws {
    let draft = try blocklistDraft(entries: [
        .domain(try DomainName("example.test")),
        .address(IPInterval(exact: try IPAddress("203.0.113.8"))),
    ])
    try PolicyConfigurationValidator.validate(draft)
    let data = try ConfigurationArchiveCodec.export(
        draft: draft,
        appVersion: "test",
        now: Date(timeIntervalSince1970: 10)
    )
    #expect(try ConfigurationArchiveCodec.decode(data).rules.count == 2)
}

@Test func blocklistConfigurationRejectsForgedBroadRuleAndStatusMismatch() throws {
    let valid = try blocklistDraft(entries: [.domain(try DomainName("example.test"))])
    let original = try #require(valid.rules.first)
    let broad = try managedRule(
        sourceID: valid.blocklists[0].id,
        lineageID: valid.lineageID,
        destination: .anyEndpoint,
        enabled: true
    )
    #expect(throws: PolicyConfigurationValidationError.invalidBlocklistRules) {
        try PolicyConfigurationValidator.validate(copy(valid, rules: [broad]))
    }

    let disabled = BlocklistSource(
        id: valid.blocklists[0].id,
        name: valid.blocklists[0].name,
        importedAt: valid.blocklists[0].importedAt,
        entryCount: 1,
        domainEntryCount: 1,
        addressEntryCount: 0,
        contentHash: valid.blocklists[0].contentHash,
        status: .disabled
    )
    #expect(original.isEnabled)
    #expect(throws: PolicyConfigurationValidationError.invalidBlocklistRules) {
        try PolicyConfigurationValidator.validate(copy(valid, sources: [disabled]))
    }
}

@Test func checksumValidArchiveCannotCarryDuplicateManagedMembership() throws {
    let valid = try blocklistDraft(entries: [.domain(try DomainName("example.test"))])
    let duplicate = try managedRule(
        sourceID: valid.blocklists[0].id,
        lineageID: valid.lineageID,
        destination: valid.rules[0].destination,
        enabled: true
    )
    let source = BlocklistSource(
        id: valid.blocklists[0].id,
        name: valid.blocklists[0].name,
        importedAt: valid.blocklists[0].importedAt,
        entryCount: 2,
        domainEntryCount: 2,
        addressEntryCount: 0,
        contentHash: valid.blocklists[0].contentHash,
        status: .active
    )
    let forged = copy(valid, rules: valid.rules + [duplicate], sources: [source])
    #expect(throws: PolicyConfigurationValidationError.invalidBlocklistRules) {
        _ = try ConfigurationArchiveCodec.export(
            draft: forged,
            appVersion: "test",
            now: Date(timeIntervalSince1970: 10)
        )
    }
}

private func blocklistDraft(entries: [BlocklistEntry]) throws -> PolicyConfigurationDraft {
    let lineage = UUID()
    let result = try BlocklistImportBuilder.build(
        entries: entries,
        name: "Fixture",
        contentHash: Data(SHA256.hash(data: Data("fixture".utf8))),
        lineageID: lineage,
        now: Date(timeIntervalSince1970: 1)
    )
    return PolicyConfigurationDraft(
        lineageID: lineage,
        authorizedUID: 501,
        operationMode: .silentAllow,
        baseOperationMode: .silentAllow,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: result.rules,
        localGroups: [],
        profiles: [],
        blocklists: [result.source]
    )
}

private func managedRule(
    sourceID: UUID,
    lineageID: UUID,
    destination: DestinationCondition,
    enabled: Bool
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
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
}

private func copy(
    _ draft: PolicyConfigurationDraft,
    rules: [Rule]? = nil,
    sources: [BlocklistSource]? = nil
) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: draft.lineageID,
        authorizedUID: draft.authorizedUID,
        operationMode: draft.operationMode,
        baseOperationMode: draft.baseOperationMode,
        activeProfileID: draft.activeProfileID,
        enabledLocalGroupIDs: draft.enabledLocalGroupIDs,
        rules: rules ?? draft.rules,
        localGroups: draft.localGroups,
        profiles: draft.profiles,
        blocklists: sources ?? draft.blocklists
    )
}
