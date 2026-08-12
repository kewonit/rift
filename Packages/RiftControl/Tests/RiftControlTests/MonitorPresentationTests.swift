import RiftControl
import RiftCore
import RiftIPC
import Foundation
import Testing

@Test func summaryDoesNotTreatMissingBytesAsZero() throws {
    let rows = [
        try displayRow(sequence: 1, hostname: "one.example", inbound: nil, outbound: nil),
    ]
    let summary = MonitorSummaryBuilder.build(from: rows)
    #expect(summary.sent == .unavailable)
    #expect(summary.received == .unavailable)
}

@Test func summaryDistinguishesExactAndLowerBoundTotals() throws {
    let exactRows = [
        try displayRow(sequence: 1, hostname: "one.example", inbound: 20, outbound: 10),
        try displayRow(sequence: 2, hostname: "two.example", inbound: 40, outbound: 30),
    ]
    let exact = MonitorSummaryBuilder.build(from: exactRows)
    #expect(exact.sent == ReportedByteTotal.exact(40))
    #expect(exact.received == ReportedByteTotal.exact(60))
    #expect(exact.isComplete)

    let partialRows = exactRows + [
        try displayRow(
            sequence: 3, hostname: "three.example", inbound: nil, outbound: nil,
            closed: false
        ),
    ]
    let partial = MonitorSummaryBuilder.build(from: partialRows)
    #expect(partial.sent == ReportedByteTotal.lowerBound(40))
    #expect(partial.received == ReportedByteTotal.lowerBound(60))
    #expect(
        MonitorSummaryBuilder.build(from: exactRows, queryComplete: false).sent
            == ReportedByteTotal.lowerBound(40)
    )
    #expect(!MonitorSummaryBuilder.build(from: exactRows, queryComplete: false).isComplete)
}

@Test func summaryRejectsOverflowAndMarksCoverageGapsPartial() throws {
    let overflowRows = [
        try displayRow(sequence: 1, hostname: "one.example", inbound: .max, outbound: .max),
        try displayRow(sequence: 2, hostname: "two.example", inbound: 1, outbound: 1),
    ]
    let overflow = MonitorSummaryBuilder.build(from: overflowRows)
    #expect(overflow.sent == .unavailable)
    #expect(overflow.received == .unavailable)

    let gapRows = [
        try displayRow(
            sequence: 3, hostname: "three.example", inbound: 20, outbound: 10,
            coverage: .gap
        ),
    ]
    let gap = MonitorSummaryBuilder.build(from: gapRows)
    #expect(gap.sent == ReportedByteTotal.lowerBound(10))
    #expect(gap.received == ReportedByteTotal.lowerBound(20))
    #expect(gap.coverage == .gap)
    #expect(!gap.isComplete)
}

@Test func summaryTopListTiesUseStableNormalizedLabels() throws {
    let rows = [
        try displayRow(sequence: 1, hostname: "z.example", inbound: 1, outbound: 1),
        try displayRow(sequence: 2, hostname: "A.example", inbound: 1, outbound: 1),
        try displayRow(sequence: 3, hostname: "m.example", inbound: 1, outbound: 1),
    ]
    let summary = MonitorSummaryBuilder.build(from: rows, topLimit: 2)
    #expect(summary.topDestinations.map(\.id) == ["host:a.example", "host:m.example"])
}

@Test func summaryUsesStableIdentityAndDestinationCounts() throws {
    let rows = [
        try displayRow(sequence: 1, hostname: "same.example", inbound: 1, outbound: 1),
        try displayRow(sequence: 2, hostname: "same.example", inbound: 1, outbound: 1),
        try displayRow(
            sequence: 3, hostname: "other.example", inbound: 1, outbound: 1,
            action: .deny, direction: .incoming
        ),
        try displayRow(
            sequence: 4, hostname: "fallback.example", inbound: 1, outbound: 1,
            reason: .unmatchedModeFallback
        ),
    ]
    let summary = MonitorSummaryBuilder.build(from: rows)
    #expect(summary.processCount == 1)
    #expect(summary.destinationCount == 3)
    #expect(summary.allowed == 2)
    #expect(summary.denied == 1)
    #expect(summary.unresolved == 1)
    #expect(summary.incoming == 1)
    #expect(
        summary.topApplications.first?.presentationIdentity
            == rows.first?.source.event.flow.sourceAppIdentity
    )
    #expect(summary.topDestinations.first?.id == "host:same.example")
    #expect(summary.topDestinations.first?.count == 2)
}

@Test func coarseOriginQuantizesClampsAndWraps() throws {
    let value = try CoarseMapCoordinate(latitude: 91, longitude: 181.12)
    #expect(value.latitude == 85)
    #expect(value.longitude == -179)
    let opposite = try CoarseMapCoordinate(latitude: -91, longitude: -181.12)
    #expect(opposite.latitude == -85)
    #expect(opposite.longitude == 179)
    #expect(try CoarseMapCoordinate(latitude: 0, longitude: 179.99).longitude == -180)
    #expect(try CoarseMapCoordinate(latitude: 0, longitude: 540).longitude == -180)
    #expect(throws: GeoLocationError.invalidCoordinate) {
        _ = try CoarseMapCoordinate(latitude: .nan, longitude: 0)
    }
    #expect(throws: GeoLocationError.invalidCoordinate) {
        _ = try CoarseMapCoordinate(latitude: 0, longitude: .infinity)
    }
}

@Test func mapSelectionIsBoundedStableAndKeepsSelection() throws {
    var locations: [MonitorDisplayRow] = []
    for index in 0..<240 {
        let row = try displayRow(
            sequence: UInt64(index + 1),
            hostname: "\(index).example",
            inbound: 1,
            outbound: 1,
            latitude: Double((index % 120) - 60),
            longitude: Double(index - 120)
        )
        locations.append(row)
    }
    let selectedID = locations.last?.geography.location?.stableID
    let selection = MonitorMapSelector.select(from: locations, selectedID: selectedID)
    #expect(selection.totalLocationCount == 240)
    #expect(selection.markers.count == 200)
    #expect(selection.links.count == 32)
    #expect(selection.markers.first?.id == selectedID)
}

@Test func mapViewportUsesTheShortAntimeridianArcAndBoundsPoles() throws {
    let antimeridian = MonitorMapGeometry.viewport(for: [
        try MonitorMapPosition(latitude: 10, longitude: 179),
        try MonitorMapPosition(latitude: 12, longitude: -179),
    ])
    let wrapped = try #require(antimeridian)
    #expect(abs(abs(wrapped.centerLongitude) - 180) < 0.001)
    #expect(wrapped.longitudeDelta < 3)

    let poles = MonitorMapGeometry.viewport(for: [
        try MonitorMapPosition(latitude: 90, longitude: 0),
        try MonitorMapPosition(latitude: -90, longitude: 0),
    ])
    let bounded = try #require(poles)
    #expect(bounded.centerLatitude == 0)
    #expect(bounded.latitudeDelta == 170)
    #expect(throws: GeoLocationError.invalidCoordinate) {
        _ = try MonitorMapPosition(latitude: .infinity, longitude: 0)
    }
}

private func displayRow(
    sequence: UInt64,
    hostname: String,
    inbound: UInt64?,
    outbound: UInt64?,
    closed: Bool = true,
    action: FilterAction = .allow,
    direction: TrafficDirection = .outgoing,
    reason: RuntimeEventReason = .concreteDecision,
    coverage: HistoryCoverage = .complete,
    latitude: Double = 51.5,
    longitude: Double = -0.1
) throws -> MonitorDisplayRow {
    let provider = try #require(UUID(uuidString: "612E26C2-C04B-42EA-90E9-78BD0567799C"))
    let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "RIFTPREVIEW", signingIdentifier: "io.rift.preview"
    ))
    let domain = try DomainName(hostname)
    let endpoint = Endpoint(
        address: try IPAddress("203.0.113.\((sequence % 250) + 1)"),
        port: 443,
        hostname: domain,
        hostnameCoverage: .observed,
        classes: [],
        interfaceSnapshotGeneration: 1
    )
    let occurredAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence))
    let event = RuntimeEvent(
        providerEpoch: provider,
        sequence: sequence,
        occurredAt: occurredAt,
        flow: FlowDescriptor(
            flowID: try #require(UUID(uuidString: String(
                format: "00000000-0000-4000-8000-%012llu", sequence
            ))),
            observedAt: occurredAt,
            sourceAppIdentity: identity,
            sourceProcessIdentity: identity,
            owner: .user(uid: 501),
            direction: direction,
            transportProtocol: .tcp,
            localEndpoint: nil,
            remoteEndpoint: endpoint,
            observedHostname: domain,
            metadataConfidence: [.appIdentity, .endpoint, .observedHostname, .owner]
        ),
        action: action,
        reason: reason,
        policy: nil
    )
    let row = MonitorEventRow(
        event: event,
        coverage: coverage,
        closedAt: closed ? occurredAt.addingTimeInterval(30) : nil,
        bytesInbound: inbound,
        bytesOutbound: outbound,
        flowEndReason: closed ? .networkExtensionReport : nil
    )
    let location = try GeoLocation(
        continentCode: "EU",
        countryCode: "GB",
        region: "Test",
        city: hostname,
        latitude: latitude,
        longitude: longitude
    )
    return MonitorDisplayRow(
        source: row,
        primary: "io.rift.preview",
        secondary: hostname,
        geography: .located(location)
    )
}
