import AbyssControl
import AbyssCore
import Foundation
import Testing

@Test func legacyBroadElevatedRuleRequiresNarrowingBeforeMutationOrConfigurationSave() throws {
    let legacy = try legacyBroadElevatedRule()
    let configuration = PolicyConfigurationDraft(
        lineageID: legacy.lineageID,
        authorizedUID: 501,
        operationMode: .silentAllow,
        baseOperationMode: .silentAllow,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: [legacy],
        localGroups: [],
        profiles: [],
        blocklists: []
    )
    #expect(throws: RuleValidationError.elevatedPriorityRequiresExactProcess) {
        try PolicyConfigurationValidator.validate(configuration)
    }
    #expect(throws: RuleValidationError.elevatedPriorityRequiresExactProcess) {
        try RuleMutation.edited(
            legacy,
            action: legacy.action,
            priority: legacy.priority,
            process: legacy.process,
            destination: legacy.destination,
            transport: legacy.transportProtocol,
            port: legacy.port,
            direction: legacy.direction,
            owner: legacy.owner,
            profileID: legacy.profileID,
            localGroupID: legacy.localGroupID,
            expiresAt: legacy.expiresAt,
            isEnabled: legacy.isEnabled,
            reviewState: legacy.reviewState,
            note: legacy.notes,
            now: Date(timeIntervalSince1970: 2)
        )
    }

    let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAMID1234",
        signingIdentifier: "com.example.client"
    ))
    let destination = try DestinationCondition.normalizedExactHostnameSet([
        DomainName("api.example.com"),
    ])
    let narrowed = try RuleMutation.edited(
        legacy,
        action: legacy.action,
        priority: legacy.priority,
        process: .exact(identity),
        destination: destination,
        transport: legacy.transportProtocol,
        port: legacy.port,
        direction: legacy.direction,
        owner: legacy.owner,
        profileID: legacy.profileID,
        localGroupID: legacy.localGroupID,
        expiresAt: legacy.expiresAt,
        isEnabled: legacy.isEnabled,
        reviewState: legacy.reviewState,
        note: legacy.notes,
        now: Date(timeIntervalSince1970: 2)
    )
    try PolicyConfigurationValidator.validate(PolicyConfigurationDraft(
        lineageID: configuration.lineageID,
        authorizedUID: configuration.authorizedUID,
        operationMode: configuration.operationMode,
        baseOperationMode: configuration.baseOperationMode,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: [narrowed],
        localGroups: [],
        profiles: [],
        blocklists: []
    ))
}

private func legacyBroadElevatedRule() throws -> Rule {
    let ordinary = try Rule(
        id: UUID(),
        lineageID: UUID(),
        revision: 1,
        action: .filter(.allow),
        priority: .normal,
        process: .anyProcess,
        destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol,
        port: nil,
        direction: .outgoing,
        owner: .authorizedUser,
        createdAt: Date(timeIntervalSince1970: 1),
        modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let encoded = try JSONEncoder().encode(ordinary)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["priority"] = RulePriority.elevatedUser.rawValue
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return try JSONDecoder().decode(Rule.self, from: data)
}
