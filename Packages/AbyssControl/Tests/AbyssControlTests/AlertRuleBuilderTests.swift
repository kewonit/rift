import AbyssControl
import AbyssCore
import AbyssIPC
import Foundation
import Testing

@Test func alertRuleDefaultsToExactEndpointAndAuthorizedOwner() throws {
    let lineage = UUID()
    let profileID = UUID()
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM123", signingIdentifier: "example.client")
    )
    let prompt = PromptRequest(
        nonce: UUID(),
        providerEpoch: UUID(),
        lineageID: lineage,
        generation: 4,
        flowID: UUID(),
        observedAt: Date(),
        owner: .user(uid: 501),
        appIdentity: identity,
        processIdentity: identity,
        direction: .outgoing,
        transportProtocol: .tcp,
        endpoint: Endpoint(
            address: try IPAddress("203.0.113.8"),
            port: 443,
            hostname: try DomainName("api.example.test"),
            hostnameCoverage: .observed,
            classes: [],
            interfaceSnapshotGeneration: 1
        ),
        winningRuleID: nil,
        affectingRuleIDs: []
    )
    let rule = try AlertRuleBuilder.build(
        prompt: prompt,
        action: .deny,
        lineageID: lineage,
        authorizedUID: 501,
        expiresAt: nil,
        profileID: profileID,
        notes: "Reviewed from alert",
        now: Date()
    )
    #expect(rule.process == .exact(identity))
    #expect(rule.destination == .exactHostnameSet([try DomainName("api.example.test")]))
    #expect(rule.port == (try PortRange(443, 443)))
    #expect(rule.owner == .authorizedUser)
    #expect(rule.profileID == profileID)
    #expect(rule.notes == "Reviewed from alert")
}

@Test func alertRuleRejectsForeignOwnerAndMissingIdentity() throws {
    let prompt = PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: UUID(), generation: 1,
        flowID: UUID(), observedAt: Date(), owner: .user(uid: 502),
        appIdentity: nil, processIdentity: nil, direction: .outgoing,
        transportProtocol: .tcp,
        endpoint: Endpoint(
            address: try IPAddress("203.0.113.9"), port: 80, hostname: nil,
            hostnameCoverage: .absent, classes: [], interfaceSnapshotGeneration: 0
        ),
        winningRuleID: nil, affectingRuleIDs: []
    )
    #expect(throws: AlertRuleBuilderError.identityUnavailable) {
        try AlertRuleBuilder.build(
            prompt: prompt, action: .allow, lineageID: prompt.lineageID,
            authorizedUID: 501, expiresAt: nil, now: Date()
        )
    }
}

@Test func systemOwnerRequiresExplicitDurableRuleConfirmation() throws {
    let lineage = UUID()
    let identity = ProcessIdentity.applePlatform(
        try SignedCodeIdentity(teamIdentifier: nil, signingIdentifier: "com.apple.fixture")
    )
    let prompt = PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: lineage, generation: 1,
        flowID: UUID(), observedAt: Date(), owner: .system,
        appIdentity: identity, processIdentity: identity, direction: .outgoing,
        transportProtocol: .tcp,
        endpoint: Endpoint(
            address: try IPAddress("17.0.0.1"), port: 443, hostname: nil,
            hostnameCoverage: .absent, classes: [], interfaceSnapshotGeneration: 1
        ),
        winningRuleID: nil, affectingRuleIDs: []
    )
    #expect(throws: AlertRuleBuilderError.systemOwnerConfirmationRequired) {
        try AlertRuleBuilder.build(
            prompt: prompt, action: .allow, lineageID: lineage,
            authorizedUID: 501, expiresAt: nil, now: Date()
        )
    }
    let confirmed = try AlertRuleBuilder.build(
        prompt: prompt, action: .allow, lineageID: lineage,
        authorizedUID: 501, expiresAt: nil, allowSystemOwner: true, now: Date()
    )
    #expect(confirmed.owner == .system)
}

@Test func broadAlertDestinationRequiresAnExplicitScopeAndDropsTheObservedPort() throws {
    let lineage = UUID()
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM123", signingIdentifier: "example.client")
    )
    let prompt = PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: lineage, generation: 2,
        flowID: UUID(), observedAt: Date(), owner: .user(uid: 501),
        appIdentity: identity, processIdentity: identity, direction: .outgoing,
        transportProtocol: .tcp,
        endpoint: Endpoint(
            address: try IPAddress("203.0.113.19"), port: 8443,
            hostname: try DomainName("api.example.test"), hostnameCoverage: .observed,
            classes: [], interfaceSnapshotGeneration: 1
        ),
        winningRuleID: nil, affectingRuleIDs: []
    )

    let exact = try AlertRuleBuilder.build(
        prompt: prompt, action: .deny, lineageID: lineage,
        authorizedUID: 501, expiresAt: nil, now: Date()
    )
    #expect(exact.destination == .exactHostnameSet([try DomainName("api.example.test")]))
    #expect(exact.port == (try PortRange(8443, 8443)))

    let broad = try AlertRuleBuilder.build(
        prompt: prompt, action: .deny, lineageID: lineage,
        authorizedUID: 501, expiresAt: nil, destinationScope: .anyEndpoint,
        now: Date()
    )
    #expect(broad.destination == .anyEndpoint)
    #expect(broad.port == nil)
}
