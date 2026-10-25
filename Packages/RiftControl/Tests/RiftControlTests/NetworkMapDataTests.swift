import Foundation
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

private let networkDataURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/NetworkData")

private func bundledData(_ name: String) throws -> Data {
    try Data(contentsOf: networkDataURL.appendingPathComponent(name))
}

private let mumbai = GeoPoint(latitude: 19.08, longitude: 72.88)

@Test func countryTableResolvesIPv4AndIPv6AndLeavesReservedAddressesUnknown() throws {
    let table = try CountryIPTable(compressedData: bundledData("ip-country.bin"))
    #expect(table.countryCode(for: try IPAddress("1.0.0.5")) == "AU")
    #expect(table.countryCode(for: try IPAddress("1.0.2.9")) == "CN")
    #expect(table.countryCode(for: try IPAddress("2001:200::1")) == "JP")
    #expect(table.countryCode(for: try IPAddress("10.1.2.3")) == nil)
    #expect(table.countryCode(for: try IPAddress("192.0.2.1")) == nil)
    #expect(table.countryCode(for: try IPAddress("0.0.0.0")) == nil)
}

@Test func networkDataRejectsCorruptAndTruncatedFiles() throws {
    let table = try bundledData("ip-country.bin")
    #expect(throws: (any Error).self) { try CountryIPTable(compressedData: table.prefix(table.count / 2)) }
    #expect(throws: (any Error).self) { try CountryIPTable(compressedData: Data("not a table".utf8)) }
    let grid = try bundledData("country-grid.bin")
    #expect(throws: (any Error).self) { try CountryGrid(compressedData: grid.prefix(64)) }
    #expect(throws: (any Error).self) { try CountryIPTable(compressedData: grid) }
}

@Test func countryGridFindsLandSeaAndNearbyCoasts() throws {
    let grid = try CountryGrid(compressedData: bundledData("country-grid.bin"))
    #expect(grid.countryCode(at: GeoPoint(latitude: 48.86, longitude: 2.35)) == "FR")
    #expect(grid.countryCode(at: GeoPoint(latitude: 1.35, longitude: 103.82)) == "SG")
    #expect(grid.countryCode(at: GeoPoint(latitude: 30, longitude: -40)) == nil)
    #expect(grid.nearestCountryCode(to: GeoPoint(latitude: 18.9, longitude: 72.6)) == "IN")
    #expect(grid.landShare(from: GeoPoint(latitude: 52.5, longitude: 13.4),
                           to: GeoPoint(latitude: 48.9, longitude: 2.4)) > 0.9)
    #expect(grid.landShare(from: GeoPoint(latitude: 40.7, longitude: -74),
                           to: GeoPoint(latitude: 51.5, longitude: -0.1)) < 0.2)
}

@Test func cableNetworkDecodesConsistentBundledMap() throws {
    let network = try JSONDecoder().decode(UnderseaCableNetwork.self, from: bundledData("network-map.json"))
    #expect(network.cables.count > 200)
    #expect(network.cables.contains { $0.approximate })
    #expect(network.cables.contains { !$0.approximate })
    #expect(network.segments.count > network.cables.count)
    #expect(network.countries["US"] != nil && network.countries["SG"] != nil)
    #expect(network.segments.allSatisfy { segment in
        segment.path.allSatisfy { abs($0.latitude) <= 90 && abs($0.longitude) <= 180 }
    })
}

@Test func routerSendsLongDistanceTrafficThroughUnderseaCables() throws {
    let router = try makeRouter()
    guard case .undersea(let legs, let destination) = router.route(from: mumbai, toCountry: "US") else {
        Issue.record("Expected an undersea route from Mumbai to the United States")
        return
    }
    #expect(legs.contains { if case .cable = $0.kind { true } else { false } })
    #expect(legs.first?.points.first == mumbai)
    #expect(legs.last?.points.last == destination)
    #expect(legs.allSatisfy { $0.points.count >= 2 })
}

@Test func routerKeepsDomesticAndOverlandTrafficOffCables() throws {
    let router = try makeRouter()
    #expect(router.route(from: mumbai, toCountry: "IN") == .domestic(destination: try #require(
        router.route(from: mumbai, toCountry: "IN").destination
    )))
    if case .overland = router.route(from: GeoPoint(latitude: 52.52, longitude: 13.40), toCountry: "FR") {} else {
        Issue.record("Expected Berlin to France to stay overland")
    }
    #expect(router.route(from: mumbai, toCountry: "ZZ") == .unavailable)
}

@Test func antimeridianSplitNeverDrawsAcrossTheWorld() {
    let parts = NetworkMapGeometry.splitAtAntimeridian([
        GeoPoint(latitude: 10, longitude: 170),
        GeoPoint(latitude: 12, longitude: 179),
        GeoPoint(latitude: 14, longitude: -179),
        GeoPoint(latitude: 16, longitude: -170),
    ])
    #expect(parts.count == 2)
    #expect(parts[0].last?.longitude == 180)
    #expect(parts[1].first?.longitude == -180)
    #expect(parts.allSatisfy { part in zip(part, part.dropFirst()).allSatisfy { abs($1.longitude - $0.longitude) <= 180 } })
    #expect(NetworkMapGeometry.splitAtAntimeridian([GeoPoint(latitude: 0, longitude: 0)]).isEmpty)
}

private func makeRouter() throws -> CableRouter {
    CableRouter(
        network: try JSONDecoder().decode(UnderseaCableNetwork.self, from: bundledData("network-map.json")),
        grid: try CountryGrid(compressedData: bundledData("country-grid.bin"))
    )
}

@Test func countryActivityGroupsPublicDestinationsAndSkipsLocalOnes() throws {
    let rows = [
        try countryRow("8.8.8.8", action: .allow),
        try countryRow("8.8.4.4", action: .deny),
        try countryRow("1.0.2.9", action: .deny),
        try countryRow("192.168.1.20", action: .allow, classes: [.localNetwork]),
        try countryRow("203.0.113.9", action: .allow),
    ]
    let codes = ["8.8.8.8": "US", "8.8.4.4": "US", "1.0.2.9": "CN"]
    let activity = CountryActivityBuilder.build(rows) { codes[$0.description] }
    #expect(activity.map(\.countryCode) == ["US", "CN"])
    #expect(activity[0].connections == 2 && activity[0].blocked == 1 && !activity[0].allBlocked)
    #expect(activity[1].allBlocked)
    #expect(CountryActivityBuilder.build(rows, limit: 1) { codes[$0.description] }.count == 1)
}

private func countryRow(
    _ address: String,
    action: FilterAction,
    classes: Set<EndpointClass> = []
) throws -> MonitorDisplayRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(timeIntervalSince1970: 1_000),
        sourceAppIdentity: identity, sourceProcessIdentity: identity,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress(address), port: 443, hostname: nil,
            hostnameCoverage: .absent, classes: classes, interfaceSnapshotGeneration: 1
        ),
        observedHostname: nil, metadataConfidence: [.appIdentity, .endpoint]
    )
    let row = MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: flow.observedAt,
            flow: flow, action: action, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete
    )
    return MonitorDisplayRow(source: row, primary: "example.client", secondary: address)
}
