import AbyssControl
import AbyssCore
import AbyssIPC
import Foundation
import Testing

@Test func monitorHierarchyHasStableCanonicalPathsForEveryLens() throws {
    let row = try monitorHierarchyRow()
    let location = try GeoLocation(
        continentCode: "NA", countryCode: "US", region: "California",
        city: "Los Angeles", latitude: 34.05, longitude: -118.24
    )
    let geography = [row.id: GeoResolution.located(location)]
    let display = MonitorQuery.filter(
        [row], search: "", lens: .application, geography: geography
    )
    let coverage = [row.id: MonitorRuleCoverage(state: .noRule)]
    let appNodes = MonitorHierarchyBuilder.build(display, lens: .application, coverages: coverage)
    let hostnameNodes = MonitorHierarchyBuilder.build(
        display, lens: .hostname, coverages: coverage
    )
    let locationNodes = MonitorHierarchyBuilder.build(
        display, lens: .location, coverages: coverage
    )
    #expect(appNodes.first?.kind == .application)
    #expect(appNodes.first?.exactRuleSeed != nil)
    #expect(hostnameNodes.first?.kind == .hostname)
    #expect(locationNodes.first?.kind == .country)
    #expect(locationNodes.first?.children?.first?.kind == .city)
    #expect(MonitorHierarchyBuilder.node(forEventID: row.id, in: appNodes)?.eventID == row.id)
    #expect(MonitorHierarchyBuilder.node(
        forEventID: row.id, in: hostnameNodes
    )?.eventID == row.id)
    #expect(MonitorHierarchyBuilder.node(
        forEventID: row.id, in: locationNodes
    )?.eventID == row.id)
    let leaf = try #require(MonitorHierarchyBuilder.node(forEventID: row.id, in: appNodes))
    #expect(MonitorHierarchyBuilder.node(withID: leaf.id, in: appNodes)?.eventID == row.id)
}

@Test func monitorRevealClearsEveryExcludingFilterOnly() {
    var query = MonitorQueryState(
        search: "hidden",
        lens: .hostname,
        decision: .denied,
        direction: .incoming,
        time: .hour,
        timeAnchor: Date(timeIntervalSince1970: 100),
        selectedTimeRange: Date(timeIntervalSince1970: 10)...Date(timeIntervalSince1970: 20),
        sort: .name,
        focusedLocationID: "location"
    )
    query.clearExcludingFilters()
    #expect(query.search.isEmpty)
    #expect(query.decision == .all)
    #expect(query.direction == .all)
    #expect(query.time == .all)
    #expect(query.timeAnchor == nil)
    #expect(query.selectedTimeRange == nil)
    #expect(query.focusedLocationID == nil)
    #expect(query.lens == .hostname)
    #expect(query.sort == .name)
}

@Test func hostnameLensGroupsTheExactObservedHostnameWithoutDuplicateLevels() throws {
    let rows = try [
        monitorHierarchyRow(address: "203.0.113.10", port: 443, sequence: 1),
        monitorHierarchyRow(address: "198.51.100.8", port: 8443, sequence: 2),
    ]
    let display = MonitorQuery.filter(rows, search: "", lens: .hostname)
    let nodes = MonitorHierarchyBuilder.build(display, lens: .hostname, coverages: [:])
    let hostname = try #require(nodes.first)
    #expect(nodes.count == 1)
    #expect(hostname.kind == .hostname)
    #expect(hostname.title == DisplaySanitizer.plainText("api.example.test"))
    #expect(hostname.children?.first?.kind == .application)
    #expect(hostname.children?.contains { $0.kind == .hostname || $0.kind == .address } == false)
}

@Test func hostnameLensDoesNotInferSuffixBoundariesOrCollideWithIPAddressText() throws {
    let rows = try [
        monitorHierarchyRow(hostname: "api.example.co.uk", sequence: 1),
        monitorHierarchyRow(hostname: "www.example.co.uk", sequence: 2),
        monitorHierarchyRow(
            hostname: "203.0.113.10", address: "198.51.100.8", sequence: 3
        ),
        monitorHierarchyRow(hostname: nil, address: "203.0.113.10", sequence: 4),
    ]
    let display = MonitorQuery.filter(rows, search: "", lens: .hostname)
    let nodes = MonitorHierarchyBuilder.build(display, lens: .hostname, coverages: [:])
    #expect(nodes.count == 4)
    #expect(Set(nodes.map(\.title)) == Set([
        "api.example.co.uk", "www.example.co.uk", "203.0.113.10", "Hostname unavailable",
    ].map { DisplaySanitizer.plainText($0) }))
    #expect(Set(nodes.map(\.id)).count == 4)
    let unavailable = try #require(nodes.first {
        $0.title == DisplaySanitizer.plainText("Hostname unavailable")
    })
    #expect(unavailable.children?.first?.kind == .address)
    #expect(unavailable.children?.first?.title == DisplaySanitizer.plainText("203.0.113.10"))
    let numericHostname = try #require(nodes.first {
        $0.title == DisplaySanitizer.plainText("203.0.113.10")
    })
    #expect(numericHostname.children?.first?.kind == .application)
}

@Test func monitorHierarchyNeverMergesSameLabelAcrossTeams() throws {
    let first = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAMONE", signingIdentifier: "example.client"
    ))
    let second = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAMTWO", signingIdentifier: "example.client"
    ))
    let rows = try [monitorHierarchyRow(identity: first), monitorHierarchyRow(identity: second)]
    let display = MonitorQuery.filter(rows, search: "", lens: .application)
    let nodes = MonitorHierarchyBuilder.build(display, lens: .application, coverages: [:])
    #expect(nodes.count == 2)
    #expect(Set(nodes.compactMap(\.presentationIdentity)) == [first, second])
}

@Test func monitorCoverageUsesMatcherAndDistinguishesExactFromBroader() throws {
    let row = try monitorHierarchyRow()
    let exact = try monitorRule(for: row, exact: true)
    let broader = try monitorRule(for: row, exact: false)
    let exactConfiguration = monitorConfiguration(rules: [exact])
    let broadConfiguration = monitorConfiguration(rules: [broader])
    #expect(MonitorCoverageEvaluator.evaluate(
        [row], configuration: exactConfiguration, enforcementState: .enforced
    )[row.id]?.state == .exact)
    #expect(MonitorCoverageEvaluator.evaluate(
        [row], configuration: broadConfiguration, enforcementState: .enforced
    )[row.id]?.state == .broader)
    #expect(MonitorCoverageEvaluator.evaluate(
        [row], configuration: exactConfiguration,
        enforcementState: .savedPendingEnforcement
    )[row.id]?.state == .savedPendingEnforcement)
}

@Test func monitorCoverageSeparatesEventPolicyFromCurrentRules() throws {
    let base = try monitorHierarchyRow()
    let exact = try monitorRule(for: base, exact: true)
    let configuration = monitorConfiguration(rules: [exact])
    let historical = PolicyTuple(
        lineageID: configuration.lineageID,
        generation: 1,
        hash: Data(repeating: 1, count: 32)
    )
    let desired = PolicyTuple(
        lineageID: configuration.lineageID,
        generation: 2,
        hash: Data(repeating: 2, count: 32)
    )
    let changed = replacingEventEvidence(base, policy: historical, winningRuleID: exact.id)
    #expect(MonitorCoverageEvaluator.evaluate(
        [changed], configuration: configuration, enforcementState: .enforced,
        desiredTuple: desired
    )[changed.id]?.state == .policyChanged)

    let missingConfiguration = monitorConfiguration(rules: [])
    let missing = replacingEventEvidence(base, policy: desired, winningRuleID: exact.id)
    #expect(MonitorCoverageEvaluator.evaluate(
        [missing], configuration: missingConfiguration, enforcementState: .enforced,
        desiredTuple: desired
    )[missing.id]?.state == .historicalRuleMissing)
}

@Test func monitorExactSeedRefusesUnknownIdentityAndProducesOneRuleScope() throws {
    let row = try monitorHierarchyRow()
    let seed = try #require(MonitorExactRuleSeed.make(from: row))
    #expect(seed.port.lowerBound == 443)
    #expect(seed.port.upperBound == 443)
    guard case .exactHostnameSet(let hosts) = seed.destination else {
        Issue.record("Expected an exact observed-hostname scope")
        return
    }
    #expect(hosts.map(\.ascii) == ["api.example.test"])

    let flow = row.event.flow
    let unknownFlow = FlowDescriptor(
        flowID: UUID(), observedAt: flow.observedAt,
        sourceAppIdentity: nil, sourceProcessIdentity: nil, owner: flow.owner,
        direction: flow.direction, transportProtocol: flow.transportProtocol,
        localEndpoint: flow.localEndpoint, remoteEndpoint: flow.remoteEndpoint,
        observedHostname: flow.observedHostname, metadataConfidence: flow.metadataConfidence
    )
    let unknown = MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: row.event.providerEpoch, sequence: 2,
            occurredAt: row.event.occurredAt, flow: unknownFlow,
            action: .allow, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete
    )
    #expect(MonitorExactRuleSeed.make(from: unknown) == nil)
}

private func monitorHierarchyRow(
    identity: ProcessIdentity? = nil,
    hostname: String? = "api.example.test",
    address: String = "203.0.113.10",
    port: UInt16 = 443,
    sequence: UInt64 = 1
) throws -> MonitorEventRow {
    let defaultIdentity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let resolvedIdentity = identity ?? defaultIdentity
    let host = try hostname.map(DomainName.init)
    var confidence: MetadataConfidence = [.appIdentity, .endpoint]
    if host != nil { confidence.insert(.observedHostname) }
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(timeIntervalSince1970: 1_000),
        sourceAppIdentity: resolvedIdentity, sourceProcessIdentity: resolvedIdentity,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress(address), port: port,
            hostname: host, hostnameCoverage: host == nil ? .absent : .observed, classes: [],
            interfaceSnapshotGeneration: 1
        ),
        observedHostname: host, metadataConfidence: confidence
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: sequence, occurredAt: flow.observedAt,
            flow: flow, action: .allow, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete, bytesInbound: 20, bytesOutbound: 10
    )
}

private func monitorRule(for row: MonitorEventRow, exact: Bool) throws -> Rule {
    let seed = try #require(MonitorExactRuleSeed.make(from: row))
    return try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(.allow),
        priority: .normal,
        process: exact ? seed.process : .anyProcess,
        destination: exact ? seed.destination : .anyEndpoint,
        transportProtocol: exact ? seed.transport : .anySupportedProtocol,
        port: exact ? seed.port : nil,
        direction: exact ? seed.direction : .bidirectional,
        owner: seed.owner, createdAt: Date(), modifiedAt: Date()
    )
}

private func replacingEventEvidence(
    _ row: MonitorEventRow,
    policy: PolicyTuple,
    winningRuleID: UUID
) -> MonitorEventRow {
    let event = row.event
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: event.providerEpoch,
            sequence: event.sequence,
            kind: event.kind,
            occurredAt: event.occurredAt,
            flow: event.flow,
            action: event.action,
            reason: event.reason,
            policy: policy,
            winningRuleID: winningRuleID,
            affectingRuleIDs: [winningRuleID],
            explanation: event.explanation,
            bytesInbound: event.bytesInbound,
            bytesOutbound: event.bytesOutbound,
            flowEndReason: event.flowEndReason,
            notificationRequested: event.notificationRequested
        ),
        coverage: row.coverage,
        bytesInbound: row.bytesInbound,
        bytesOutbound: row.bytesOutbound
    )
}

private func monitorConfiguration(rules: [Rule]) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: UUID(), authorizedUID: 501, operationMode: .alert,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: rules
    )
}
