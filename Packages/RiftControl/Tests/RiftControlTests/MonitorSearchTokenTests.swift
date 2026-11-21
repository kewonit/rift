import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftControl

private func tokenRow(
    host: String = "api.example.test",
    transport: TransportProtocol = .tcp,
    cause timedOut: Bool = false
) throws -> MonitorEventRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let hostname = try DomainName(host)
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(timeIntervalSince1970: 1_000),
        sourceAppIdentity: identity, sourceProcessIdentity: identity,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: transport,
        localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("203.0.113.10"), port: 443,
            hostname: hostname, hostnameCoverage: .observed,
            classes: [], interfaceSnapshotGeneration: 1
        ),
        observedHostname: hostname, metadataConfidence: [.appIdentity, .endpoint, .observedHostname]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: flow.observedAt,
            flow: flow, action: .allow,
            reason: timedOut ? .promptDeadlineFallback : .concreteDecision, policy: nil
        ),
        coverage: .complete
    )
}

private let germany = MonitorSearchContext(
    countryCode: { _ in "DE" },
    countryName: { $0 == "DE" ? "Germany" : nil }
)

private func finds(_ row: MonitorEventRow, _ search: String, context: MonitorSearchContext = .none) -> Bool {
    MonitorSearchQuery(search).matches(row, context: context)
}

@Test func domainSearchFindsTheNameAndItsSubdomainsOnly() throws {
    #expect(finds(try tokenRow(host: "api.example.test"), "domain:example.test"))
    #expect(finds(try tokenRow(host: "example.test"), "domain:EXAMPLE.test."))
    #expect(!finds(try tokenRow(host: "badexample.test"), "domain:example.test"))
    #expect(!finds(try tokenRow(host: "example.test"), "domain:api.example.test"))
}

@Test func protocolSearchMatchesTheTransport() throws {
    #expect(finds(try tokenRow(transport: .udp), "proto:udp"))
    #expect(finds(try tokenRow(transport: .tcp), "protocol:TCP"))
    #expect(!finds(try tokenRow(transport: .tcp), "proto:udp"))
    #expect(!finds(try tokenRow(), "proto:icmp"))
}

@Test func countrySearchMatchesTheCodeOrTheName() throws {
    let row = try tokenRow()
    #expect(finds(row, "country:de", context: germany))
    #expect(finds(row, "country:Germany", context: germany))
    #expect(!finds(row, "country:fr", context: germany))
    #expect(!finds(row, "country:de"))
}

@Test func decisionSearchFindsTimedOutAlerts() throws {
    #expect(finds(try tokenRow(cause: true), "decision:timedout"))
    #expect(!finds(try tokenRow(cause: false), "decision:timeout"))
}

@Test func fromNowHidesEarlierConnectionsUntilCleared() throws {
    let row = try tokenRow()
    var state = MonitorQueryState(time: .all)
    #expect(state.apply(to: [row], now: Date(timeIntervalSince1970: 2_000)).count == 1)
    state.startFromNow(Date(timeIntervalSince1970: 1_500))
    #expect(state.apply(to: [row], now: Date(timeIntervalSince1970: 2_000)).isEmpty)
    state.clearExcludingFilters()
    #expect(state.apply(to: [row], now: Date(timeIntervalSince1970: 2_000)).count == 1)
}

@Test func lookingAtThePastLeavesFromNow() throws {
    var state = MonitorQueryState(time: .hour)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    state.startFromNow(now)
    state.navigateTime(.previous, now: now)
    #expect(state.startsAt == nil)
    #expect(state.effectiveTimeWindow(now: now) != nil)
}
