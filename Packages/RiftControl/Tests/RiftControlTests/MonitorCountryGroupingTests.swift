@testable import RiftControl
import RiftCore
import RiftIPC
import Foundation
import Testing

private let countries: [String: String] = [
    "203.0.113.10": "DE",
    "198.51.100.8": "JP",
]

private let context = MonitorSearchContext(
    countryCode: { countries[$0.description] },
    countryName: { ["DE": "Germany", "JP": "Japan"][$0] }
)

@Test func countryLensGroupsConnectionsByWhereThePeerIs() throws {
    let rows = try [
        peerRow(remote: "203.0.113.10", sequence: 1),
        peerRow(remote: "198.51.100.8", sequence: 2),
        // An incoming connection belongs to the country it came from, not
        // to this Mac's own address.
        peerRow(direction: .incoming, remote: "203.0.113.10", sequence: 3),
    ]
    let display = try MonitorQuery.filter(
        rows, search: "", lens: .country, decision: .all, direction: .all, locality: .all,
        owner: .all, timeWindow: #require(MonitorTimeWindow(start: nil, end: nil)), sort: .recent,
        context: context, cancellationCheck: {}
    )
    let nodes = MonitorHierarchyBuilder.build(display, lens: .country, coverages: [:], context: context)
    #expect(nodes.allSatisfy { $0.kind == .country })
    let germany = try #require(nodes.first { $0.title == DisplaySanitizer.plainText("Germany") })
    #expect(germany.eventIDs == [rows[0].id, rows[2].id])
    #expect(germany.children?.first?.kind == .application)
    #expect(nodes.contains { $0.title == DisplaySanitizer.plainText("Japan") })
}

@Test func countryLensNamesPeersWithNoCountry() throws {
    let rows = try [
        peerRow(remote: "127.0.0.1", remoteClasses: [.loopback], sequence: 1),
        peerRow(remote: "192.168.1.20", remoteClasses: [.localNetwork], sequence: 2),
        peerRow(remote: "192.0.2.1", sequence: 3),
    ]
    let display = MonitorQuery.filter(rows, search: "", lens: .country)
    let titles = MonitorHierarchyBuilder.build(display, lens: .country, coverages: [:], context: context)
        .map(\.title)
    #expect(Set(titles) == Set(["This Mac", "Local network", "Unknown location"].map {
        DisplaySanitizer.plainText($0)
    }))
}

@Test func incomingConnectionsUseThePeerForCountryNetworkAndAddressSearch() throws {
    let incoming = try peerRow(direction: .incoming, remote: "203.0.113.10", sequence: 1)
    #expect(MonitorSearchQuery("country:de").matches(incoming, context: context))
    #expect(MonitorSearchQuery("ip:203.0.113.10").matches(incoming, context: context))
    #expect(MonitorSearchQuery("ip:192.168.1.5").matches(incoming, context: context))
    // The peer is on the internet even though this Mac's address is local.
    #expect(MonitorQuery.filter([incoming], search: "", lens: .application, locality: .internet).count == 1)
    #expect(MonitorQuery.filter([incoming], search: "", lens: .application, locality: .local).isEmpty)
    let display = MonitorQuery.filter([incoming], search: "", lens: .application)
    let activity = CountryActivityBuilder.build(display) { countries[$0.description] }
    #expect(activity.map(\.countryCode) == ["DE"])
}

private func peerRow(
    direction: TrafficDirection = .outgoing,
    remote: String,
    remoteClasses: Set<EndpointClass> = [],
    sequence: UInt64
) throws -> MonitorEventRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let local = Endpoint(
        address: try IPAddress("192.168.1.5"), port: direction == .incoming ? 22 : 50_000,
        hostname: nil, hostnameCoverage: .absent, classes: [.localNetwork],
        interfaceSnapshotGeneration: 1
    )
    let peer = Endpoint(
        address: try IPAddress(remote), port: direction == .incoming ? 50_000 : 443,
        hostname: nil, hostnameCoverage: .absent, classes: remoteClasses,
        interfaceSnapshotGeneration: 1
    )
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(timeIntervalSince1970: 1_000),
        sourceAppIdentity: identity, sourceProcessIdentity: identity,
        owner: .user(uid: 501), direction: direction, transportProtocol: .tcp,
        localEndpoint: local, remoteEndpoint: peer,
        observedHostname: nil, metadataConfidence: [.appIdentity, .endpoint]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: sequence, occurredAt: flow.observedAt,
            flow: flow, action: .allow, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete, bytesInbound: 20, bytesOutbound: 10
    )
}

@Test func summaryCountsWhatTheListShows() throws {
    let rows = try [
        peerRow(remote: "203.0.113.10", sequence: 1),
        peerRow(remote: "203.0.113.10", sequence: 2),
        peerRow(direction: .incoming, remote: "198.51.100.8", sequence: 3),
        peerRow(remote: "192.168.1.20", remoteClasses: [.localNetwork], sequence: 4),
    ]
    let display = MonitorQuery.filter(rows, search: "", lens: .application)
    let summary = MonitorSummary.make(display, context: context)
    #expect(summary.connections == 4)
    #expect(summary.apps == 1)
    #expect(summary.incoming == 1)
    #expect(summary.blocked == 0)
    #expect(summary.bytesInbound == 80)
    #expect(summary.bytesOutbound == 40)
    // The local peer has no country.
    #expect(summary.topCountries.map(\.title) == ["Germany", "Japan"].map { DisplaySanitizer.plainText($0) })
    #expect(summary.topCountries.first?.connections == 2)
    #expect(summary.topCountries.first?.id == "country:DE")
}
