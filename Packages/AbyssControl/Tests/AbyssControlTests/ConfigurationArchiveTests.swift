import AbyssControl
import AbyssCore
import Foundation
import Testing

@Test func configurationArchiveRoundTripsAndRejectsCorruption() throws {
    let lineage = UUID()
    let blocklist = try BlocklistImportBuilder.build(
        entries: [
            .domain(try DomainName("example.test")),
            .address(IPInterval(exact: try IPAddress("203.0.113.8"))),
        ],
        name: "Local deny list",
        contentHash: Data(repeating: 7, count: 32),
        lineageID: lineage,
        now: Date(timeIntervalSince1970: 50)
    )
    let draft = PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: blocklist.rules,
        blocklists: [blocklist.source]
    )
    let bytes = try ConfigurationArchiveCodec.export(draft: draft, appVersion: "1.0", now: Date())
    let decoded = try ConfigurationArchiveCodec.decode(bytes)
    #expect(decoded.rules == blocklist.rules)
    #expect(decoded.blocklists == [blocklist.source])
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var counts = try #require(object["counts"] as? [String: Any])
    counts["rules"] = blocklist.rules.count + 1
    object["counts"] = counts
    let wrongCounts = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ConfigurationArchiveError.countMismatch) {
        try ConfigurationArchiveCodec.decode(wrongCounts)
    }
    object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["checksum"] = Data(repeating: 0, count: 32).base64EncodedString()
    let corrupt = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try ConfigurationArchiveCodec.decode(corrupt) }

    object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var payload = try #require(object["payload"] as? [String: Any])
    var rules = try #require(payload["rules"] as? [[String: Any]])
    rules[0]["futureRuleField"] = true
    payload["rules"] = rules
    object["payload"] = payload
    let nestedUnknown = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes]
    )
    #expect(throws: ConfigurationArchiveError.invalidShape) {
        try ConfigurationArchiveCodec.decode(nestedUnknown)
    }
}

@Test func configurationArchiveRejectsUnknownShapeAndProtectedFeatureRules() throws {
    let lineage = UUID()
    let feature = try Rule(
        id: UUID(), lineageID: lineage, revision: 1,
        action: .filter(.allow), priority: .normal, process: .anyProcess,
        destination: .anyEndpoint, transportProtocol: .tcp, port: nil,
        direction: .outgoing, owner: .authorizedUser,
        flags: [.protected], source: .feature(identifier: "self-traffic"),
        createdAt: Date(), modifiedAt: Date()
    )
    let draft = PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: [feature]
    )
    let bytes = try ConfigurationArchiveCodec.export(
        draft: draft, appVersion: "1", now: Date()
    )
    #expect(throws: ConfigurationArchiveError.protectedSource) {
        try ConfigurationArchiveCodec.decode(bytes)
    }

    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["unexpected"] = true
    let unknown = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ConfigurationArchiveError.invalidShape) {
        try ConfigurationArchiveCodec.decode(unknown)
    }
}

@Test func configurationArchiveRejectsNonCanonicalDefinitionsAndRuntimeOnlyModes() throws {
    let timestamp = Date(timeIntervalSince1970: 100)
    let nonCanonicalGroup = LocalRuleGroup(
        id: UUID(), name: " Padded", note: "", isEnabled: true,
        createdAt: timestamp, modifiedAt: timestamp
    )
    let invalidNameDraft = PolicyConfigurationDraft(
        lineageID: UUID(), authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [nonCanonicalGroup.id], rules: [],
        localGroups: [nonCanonicalGroup]
    )
    #expect(throws: PolicyConfigurationValidationError.invalidDefinition) {
        try ConfigurationArchiveCodec.export(
            draft: invalidNameDraft, appVersion: "1", now: timestamp
        )
    }

    let degradedDraft = PolicyConfigurationDraft(
        lineageID: UUID(), authorizedUID: 501, operationMode: .degradedFallback,
        baseOperationMode: .degradedFallback, activeProfileID: nil,
        enabledLocalGroupIDs: [], rules: []
    )
    #expect(throws: PolicyConfigurationValidationError.inconsistentOperationMode) {
        try ConfigurationArchiveCodec.export(
            draft: degradedDraft, appVersion: "1", now: timestamp
        )
    }
}
