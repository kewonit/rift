import Foundation
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

private let lineage = UUID(uuidString: "A4F31042-EA13-4D42-B307-AB1D70160322")!
private let now = Date(timeIntervalSince1970: 1_000)

private func connection(
    host: String? = "api.example.test",
    port: UInt16 = 443,
    app: String = "example.client",
    direction: TrafficDirection = .outgoing
) throws -> MonitorEventRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: app)
    )
    let name = try host.map { try DomainName($0) }
    let endpoint = Endpoint(
        address: try IPAddress("203.0.113.10"), port: port, hostname: name,
        hostnameCoverage: name == nil ? .absent : .observed, classes: [],
        interfaceSnapshotGeneration: 0
    )
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: now, sourceAppIdentity: identity,
        sourceProcessIdentity: identity, owner: .user(uid: 501), direction: direction,
        transportProtocol: .tcp, localEndpoint: direction == .incoming ? endpoint : nil,
        remoteEndpoint: endpoint, observedHostname: direction == .outgoing ? name : nil,
        metadataConfidence: [.appIdentity, .endpoint, .observedHostname, .owner]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: now, flow: flow,
            action: .allow, reason: .unmatchedModeFallback, policy: nil
        ),
        coverage: .complete
    )
}

@Test func aSingleConnectionOffersEveryBreadth() throws {
    let options = MonitorRuleScope.options(for: [try connection()])
    #expect(options == [.thisHost, .allDestinations, .exactConnection])
}

@Test func anAppWithSeveralDestinationsCanStillBeBlocked() throws {
    let rows = [try connection(host: "a.example.test"), try connection(host: "b.example.test")]
    #expect(MonitorRuleScope.options(for: rows) == [.allDestinations])
}

@Test func oneSiteOnSeveralPortsCanBeBlockedAsASite() throws {
    let rows = [try connection(port: 443), try connection(port: 8443)]
    #expect(MonitorRuleScope.options(for: rows) == [.thisHost, .allDestinations])
}

@Test func differentAppsCantShareOneRule() throws {
    let rows = [try connection(app: "one.client"), try connection(app: "two.client")]
    #expect(MonitorRuleScope.options(for: rows).isEmpty)
}

@Test func incomingConnectionsKeepTheExactRule() throws {
    let row = try connection(direction: .incoming)
    #expect(MonitorRuleScope.options(for: [row]) == [.exactConnection])
}

@Test func aConnectionWithNoNameCanStillBeBlockedByAddress() throws {
    let options = MonitorRuleScope.options(for: [try connection(host: nil)])
    #expect(options.contains(.thisHost))
}

@Test func nothingOffersARuleThatCoversSubdomains() throws {
    let row = try connection()
    for breadth in MonitorRuleScope.options(for: [row]) {
        let target = try #require(try MonitorRuleScope.target(breadth, for: row))
        if case .domainSet = target.destination { Issue.record("\(breadth) covers subdomains") }
    }
}

@Test func aHostRuleCoversEveryPort() throws {
    let target = try #require(try MonitorRuleScope.target(.thisHost, for: try connection()))
    #expect(target.port == nil)
    #expect(target.transport == .anySupportedProtocol)
    #expect(target.direction == .outgoing)
}

@Test func anExactRuleKeepsItsPortAndProtocol() throws {
    let target = try #require(try MonitorRuleScope.target(.exactConnection, for: try connection()))
    #expect(target.port != nil)
    #expect(target.transport == .tcp)
}

@Test func everyScopeBuildsAValidRuleThatDecidesTheConnection() throws {
    let row = try connection()
    for breadth in MonitorRuleScope.options(for: [row]) {
        let target = try #require(try MonitorRuleScope.target(breadth, for: row))
        let configuration = PolicyConfigurationDraft(
            lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow,
            activeProfileID: nil, enabledLocalGroupIDs: [], rules: []
        )
        let result = try MonitorRulePlan.plan(
            action: .deny, priority: .normal, target: target, flow: row.event.flow,
            configuration: configuration, now: now
        ) {
            try Rule(
                id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny),
                priority: .normal, process: target.process, destination: target.destination,
                transportProtocol: target.transport, port: target.port,
                direction: target.direction, owner: target.owner, createdAt: now, modifiedAt: now
            )
        }
        guard case .changed = result else {
            Issue.record("\(breadth) didn't decide the connection: \(result)")
            continue
        }
    }
}

@Test func theCopyNeverPromisesAllProtocols() {
    for breadth in MonitorRuleBreadth.allCases {
        let text = MonitorRuleScope.title(breadth, host: "example.test", port: 443)
            + MonitorRuleScope.phrase(breadth, host: "example.test")
        #expect(!text.lowercased().contains("protocol"))
    }
}

@Test func aHostRuleSaysItMissesDirectAddressConnections() throws {
    let row = try connection()
    #expect(MonitorRuleScope.limitation(.thisHost, row: row) != nil)
    #expect(MonitorRuleScope.limitation(.allDestinations, row: row) == nil)
    #expect(MonitorRuleScope.limitation(.thisHost, row: try connection(host: nil)) == nil)
}

@Test func oneHourExpiresAndAlwaysDoesNot() {
    #expect(MonitorRuleDuration.always.expiry(from: now) == nil)
    #expect(MonitorRuleDuration.oneHour.expiry(from: now) == now.addingTimeInterval(3_600))
}

private func node(_ id: String, children: [MonitorHierarchyNode]? = nil) throws -> MonitorHierarchyNode {
    let row = try connection()
    return MonitorHierarchyNode(
        id: id, kind: .application, title: id, subtitle: nil,
        aggregate: MonitorAggregate(rows: [row]), ruleCoverage: MonitorRuleCoverage(state: .noRule),
        eventIDs: [], eventID: nil, exactRuleSeed: nil, ruleSeedEventID: nil,
        presentationIdentity: nil, children: children
    )
}

@Test func rowsStayPutWhileNewOnesJoinTheEnd() throws {
    let previous = [try node("a"), try node("b"), try node("c")]
    let updated = [try node("c"), try node("new"), try node("a"), try node("b")]
    let kept = MonitorHierarchyOrder.keepingPositions(of: previous, in: updated)
    #expect(kept.map(\.id) == ["a", "b", "c", "new"])
}

@Test func removedRowsLeaveAndChildrenStayPutToo() throws {
    let previous = [try node("a", children: [try node("x"), try node("y")]), try node("b")]
    let updated = [try node("a", children: [try node("y"), try node("x")])]
    let kept = MonitorHierarchyOrder.keepingPositions(of: previous, in: updated)
    #expect(kept.map(\.id) == ["a"])
    #expect(kept.first?.children?.map(\.id) == ["x", "y"])
}
