import RiftControl
import RiftCore
import RiftIPC
import Foundation
import Testing

@Test func ruleImpactPreviewUsesMatcherAndReportsChangedSample() throws {
    let row = try previewRow()
    let broadDeny = try previewRule(
        action: .deny,
        process: .anyProcess,
        destination: .anyEndpoint,
        transport: .anySupportedProtocol,
        port: nil,
        direction: .bidirectional
    )
    let seed = try #require(MonitorExactRuleSeed.make(from: row))
    let draft = ManualRuleDraft(
        action: .filter(.allow),
        priority: .normal,
        process: seed.process,
        destination: seed.destination,
        transport: seed.transport,
        port: seed.port,
        direction: seed.direction,
        owner: seed.owner,
        profileID: nil,
        localGroupID: nil,
        expiresAt: nil,
        isEnabled: true,
        reviewState: .reviewed,
        note: ""
    )
    let environment = RulePreviewEnvironment(
        configuration: PolicyConfigurationDraft(
            lineageID: broadDeny.lineageID,
            authorizedUID: 501,
            operationMode: .alert,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: [broadDeny]
        ),
        samples: [row]
    )
    let preview = try RuleImpactPreviewEvaluator.evaluate(
        draft: draft,
        editingRuleID: nil,
        environment: environment
    )
    #expect(preview.evaluatedCount == 1)
    #expect(preview.affectedCount == 1)
    #expect(preview.changedCount == 1)
    #expect(preview.samples.first?.candidateWins == true)
    #expect(preview.samples.first?.currentResult.hasPrefix("deny") == true)
    #expect(preview.samples.first?.proposedResult.hasPrefix("allow") == true)
}

private func previewRow() throws -> MonitorEventRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "preview.client")
    )
    let host = try DomainName("preview.example.test")
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(), sourceAppIdentity: identity,
        sourceProcessIdentity: identity, owner: .user(uid: 501), direction: .outgoing,
        transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("198.51.100.44"), port: 443,
            hostname: host, hostnameCoverage: .observed, classes: [],
            interfaceSnapshotGeneration: 1
        ),
        observedHostname: host, metadataConfidence: [.appIdentity, .endpoint]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: Date(), flow: flow,
            action: .deny, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete
    )
}

private func previewRule(
    action: FilterAction,
    process: ProcessCondition,
    destination: DestinationCondition,
    transport: ProtocolCondition,
    port: PortRange?,
    direction: DirectionCondition
) throws -> Rule {
    try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(action),
        priority: .normal, process: process, destination: destination,
        transportProtocol: transport, port: port, direction: direction,
        owner: .authorizedUser, createdAt: Date(), modifiedAt: Date()
    )
}
