import Foundation
import Testing
@testable import AbyssCore

private struct DomainGolden: Decodable {
    let input: String
    let canonical: String?
    let error: String?
}

@Test func domainGoldenFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "domain-normalization", withExtension: "json"))
    let fixture = try JSONDecoder().decode([DomainGolden].self, from: Data(contentsOf: url))
    for item in fixture {
        do {
            let value = try DomainName(item.input)
            #expect(value.ascii == item.canonical)
            #expect(item.error == nil)
        } catch {
            #expect(item.canonical == nil)
            #expect(String(describing: error) == item.error)
        }
    }
}

@Test func domainSuffixUsesLabelBoundaries() throws {
    let parent = try DomainName("example.com")
    #expect(try DomainName("api.example.com").isEqualToOrSubdomain(of: parent))
    #expect(!(try DomainName("notexample.com")).isEqualToOrSubdomain(of: parent))
}

@Test func IPAddressesAreStructuralAndCanonical() throws {
    #expect(try IPAddress("192.0.2.1").description == "192.0.2.1")
    #expect(try IPAddress("2001:0db8:0:0:0:0:0:1").description == "2001:db8::1")
    #expect(try IPAddress("::").description == "::")
    #expect(try IPAddress("::ffff:192.0.2.1") == IPAddress("192.0.2.1"))
    #expect(throws: IPAddressError.self) { try IPAddress("999.1.1.1") }
}

@Test func CIDRAndRangesValidateFamiliesAndOrdering() throws {
    let cidr = try IPInterval(cidr: IPAddress("192.0.2.129"), prefixLength: 24)
    #expect(cidr.lowerBound == (try IPAddress("192.0.2.0")))
    #expect(cidr.upperBound == (try IPAddress("192.0.2.255")))
    #expect(cidr.contains(try IPAddress("192.0.2.3")))
    #expect(!cidr.contains(try IPAddress("192.0.3.3")))
    #expect(throws: IPIntervalError.self) {
        try IPInterval(range: IPAddress("192.0.2.1"), IPAddress("2001:db8::1"))
    }
    #expect(throws: IPIntervalError.self) {
        try IPInterval(range: IPAddress("192.0.2.2"), IPAddress("192.0.2.1"))
    }
    #expect(throws: IPIntervalError.self) {
        try IPInterval(cidr: IPAddress("2001:db8::1"), prefixLength: 129)
    }
}

@Test func destinationSetsNormalizeAndEnforceBounds() throws {
    let value = IPInterval(exact: try IPAddress("203.0.113.1"))
    #expect(try DestinationCondition.normalizedIPSet([value, value]).memberCount == 1)
    #expect(throws: DestinationConditionError.self) {
        try DestinationCondition.normalizedIPSet([])
    }
    let oversized = (0...PolicyLimits.maximumDestinationMembers).map { index in
        IPInterval(exact: IPAddress(family: .ipv6, bytes: Array(repeating: 0, count: 14) + [
            UInt8(index >> 8), UInt8(truncatingIfNeeded: index),
        ]))
    }
    #expect(throws: DestinationConditionError.self) {
        try DestinationCondition.normalizedIPSet(oversized)
    }
}

@Test func portsRejectZeroAndReversal() {
    #expect(throws: PortRangeError.self) { try PortRange(0, 80) }
    #expect(throws: PortRangeError.self) { try PortRange(443, 80) }
}

@Test func storedRangesRoundTripWithoutChangingSchemaAndRejectInvalidBounds() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()

    let port = try PortRange(80, 443)
    let encodedPort = try encoder.encode(port)
    #expect(String(decoding: encodedPort, as: UTF8.self) ==
            #"{"lowerBound":80,"upperBound":443}"#)
    #expect(try decoder.decode(PortRange.self, from: encodedPort) == port)
    #expect(throws: DecodingError.self) {
        try decoder.decode(PortRange.self, from: Data(#"{"lowerBound":0,"upperBound":80}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(PortRange.self, from: Data(#"{"lowerBound":443,"upperBound":80}"#.utf8))
    }

    let interval = try IPInterval(
        range: IPAddress("192.0.2.1"),
        IPAddress("192.0.2.9")
    )
    let encodedInterval = try encoder.encode(interval)
    #expect(String(decoding: encodedInterval, as: UTF8.self) ==
            #"{"lowerBound":"192.0.2.1","upperBound":"192.0.2.9"}"#)
    #expect(try decoder.decode(IPInterval.self, from: encodedInterval) == interval)
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            IPInterval.self,
            from: Data(#"{"lowerBound":"192.0.2.9","upperBound":"192.0.2.1"}"#.utf8)
        )
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(
            IPInterval.self,
            from: Data(#"{"lowerBound":"192.0.2.1","upperBound":"2001:db8::1"}"#.utf8)
        )
    }
}

@Test func displaySanitizerBoundsAndIsolatesSpoofing() {
    let value = DisplaySanitizer.plainText("safe\nname\u{202E}txt", maximumScalars: 8)
    #expect(value.first == "⁨")
    #expect(value.last == "⁩")
    #expect(!value.contains("\n"))
    #expect(!value.contains("\u{202E}"))
    #expect(value.unicodeScalars.count == 10)
}

@Test func endpointClassificationUsesVersionedRoutesAndPreservesOverlap() throws {
    let localRoute = try IPInterval(cidr: IPAddress("192.168.50.0"), prefixLength: 24)
    let snapshot = InterfaceRouteSnapshot(
        generation: 8,
        directlyConnectedRoutes: [localRoute],
        directedBroadcasts: [try IPAddress("192.168.50.255")]
    )
    #expect(EndpointClassifier.classify(
        address: try IPAddress("192.168.50.255"),
        observedHostname: nil,
        snapshot: snapshot
    ) == [.broadcast, .localNetwork])
    #expect(EndpointClassifier.classify(
        address: try IPAddress("224.0.0.251"),
        observedHostname: try DomainName("printer.local"),
        snapshot: snapshot
    ) == [.multicast, .bonjour])
    #expect(!EndpointClassifier.classify(
        address: try IPAddress("10.0.0.1"),
        observedHostname: nil,
        snapshot: snapshot
    ).contains(.localNetwork))
    #expect(EndpointClassifier.classify(
        address: try IPAddress("fe80::1"),
        observedHostname: nil,
        snapshot: nil
    ).contains(.linkLocal))
}

@Test func interfaceRouteSnapshotsUseOnlyActiveConnectedInterfaces() throws {
    let active = InterfaceAddressRecord(
        address: try IPAddress("192.168.50.12"),
        netmask: try IPAddress("255.255.255.0"),
        broadcast: try IPAddress("192.168.50.255"),
        isUp: true,
        isRunning: true,
        isLoopback: false
    )
    let inactiveVPN = InterfaceAddressRecord(
        address: try IPAddress("10.8.0.2"),
        netmask: try IPAddress("255.255.255.0"),
        isUp: true,
        isRunning: false,
        isLoopback: false
    )
    let loopback = InterfaceAddressRecord(
        address: try IPAddress("127.0.0.1"),
        netmask: try IPAddress("255.0.0.0"),
        isUp: true,
        isRunning: true,
        isLoopback: true
    )
    let malformedMask = InterfaceAddressRecord(
        address: try IPAddress("172.16.0.1"),
        netmask: try IPAddress("255.0.255.0"),
        isUp: true,
        isRunning: true,
        isLoopback: false
    )
    let snapshot = InterfaceRouteSnapshotBuilder.build(
        generation: 12,
        records: [active, inactiveVPN, loopback, malformedMask]
    )

    #expect(snapshot.generation == 12)
    #expect(snapshot.directlyConnectedRoutes == [
        try IPInterval(cidr: IPAddress("192.168.50.12"), prefixLength: 24),
    ])
    #expect(snapshot.directedBroadcasts == [try IPAddress("192.168.50.255")])
    #expect(EndpointClassifier.classify(
        address: try IPAddress("192.168.50.44"),
        observedHostname: nil,
        snapshot: snapshot
    ).contains(.localNetwork))
    #expect(!EndpointClassifier.classify(
        address: try IPAddress("10.8.0.9"),
        observedHostname: nil,
        snapshot: snapshot
    ).contains(.localNetwork))
}

@Test func pointToPointPeerIsConnectedWithoutInventingPrivateNetworks() throws {
    let record = InterfaceAddressRecord(
        address: try IPAddress("10.20.0.2"),
        netmask: try IPAddress("255.255.255.255"),
        pointToPointPeer: try IPAddress("10.20.0.1"),
        isUp: true,
        isRunning: true,
        isLoopback: false
    )
    let snapshot = InterfaceRouteSnapshotBuilder.build(generation: 3, records: [record])

    #expect(EndpointClassifier.classify(
        address: try IPAddress("10.20.0.1"),
        observedHostname: nil,
        snapshot: snapshot
    ).contains(.localNetwork))
    #expect(!EndpointClassifier.classify(
        address: try IPAddress("10.20.0.99"),
        observedHostname: nil,
        snapshot: snapshot
    ).contains(.localNetwork))
}

@Test func parserFuzzInputsNeverBypassCanonicalRoundTrip() throws {
    var generator = DeterministicGenerator(seed: 0xAB155)
    let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:%[]")
    for _ in 0..<2_000 {
        let length = generator.index(upperBound: 80)
        let text = String((0..<length).map { _ in alphabet[generator.index(upperBound: alphabet.count)] })
        if let domain = try? DomainName(text) {
            #expect(try DomainName(domain.ascii) == domain)
        }
        if let address = try? IPAddress(text) {
            #expect(try IPAddress(address.description) == address)
        }
    }
}
