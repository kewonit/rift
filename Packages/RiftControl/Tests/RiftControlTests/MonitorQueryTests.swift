import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftControl

@Test func locationLensRequiresAdmissionAndDatabase() {
    let cases = [
        (mapUIAdmitted: false, databaseAvailable: false, expectsLocation: false),
        (mapUIAdmitted: false, databaseAvailable: true, expectsLocation: false),
        (mapUIAdmitted: true, databaseAvailable: false, expectsLocation: false),
        (mapUIAdmitted: true, databaseAvailable: true, expectsLocation: true),
    ]
    for value in cases {
        let lenses = MonitorLens.available(
            mapUIAdmitted: value.mapUIAdmitted,
            geolocationDatabaseAvailable: value.databaseAvailable
        )
        #expect(lenses.contains(.application))
        #expect(lenses.contains(.hostname))
        #expect(lenses.contains(.location) == value.expectsLocation)
    }
}

@Test func hostnameLensAndByteSortAvailabilityAreTruthful() throws {
    #expect(MonitorLens.hostname.rawValue == "Hostname")
    #expect(MonitorSort.available(allowsUnverifiedBytePreview: false).map(\.rawValue) == [
        "Most recent", "Name",
    ])
    #expect(MonitorSort.available(allowsUnverifiedBytePreview: true).map(\.rawValue)
        == MonitorSort.allCases.map(\.rawValue))

    let observed = try monitorQueryRow(hostname: "api.example.test")
    let unavailable = try monitorQueryRow(hostname: nil)
    #expect(MonitorQuery.hostnameLabel(observed) == "api.example.test")
    #expect(MonitorQuery.hostnameLabel(unavailable) == "Hostname unavailable")
    #expect(MonitorQuery.filter(
        [observed], search: "", lens: .hostname
    ).first?.primary == DisplaySanitizer.plainText("api.example.test"))
    #expect(MonitorQuery.filter(
        [unavailable], search: "", lens: .hostname
    ).first?.primary == DisplaySanitizer.plainText("Hostname unavailable"))
}

@Test func monitorSearchCombinesTokensWithAnd() throws {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(), sourceAppIdentity: identity,
        sourceProcessIdentity: identity, owner: .user(uid: 501), direction: .outgoing,
        transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("203.0.113.10"), port: 443,
            hostname: try DomainName("api.example.test"), hostnameCoverage: .observed,
            classes: [], interfaceSnapshotGeneration: 0
        ), observedHostname: try DomainName("api.example.test"),
        metadataConfidence: [.endpoint, .observedHostname]
    )
    let event = RuntimeEvent(
        providerEpoch: UUID(), sequence: 1, occurredAt: Date(), flow: flow,
        action: .deny, reason: .concreteDecision, policy: nil
    )
    let row = MonitorEventRow(event: event, coverage: .complete)
    let location = try GeoLocation(
        continentCode: "NA", countryCode: "US", region: "California",
        city: "Los Angeles", latitude: 34.05, longitude: -118.24
    )
    let geography = [row.id: GeoResolution.located(location)]
    #expect(MonitorQuery.filter([row], search: "client deny tcp", lens: .application).count == 1)
    #expect(MonitorQuery.filter([row], search: "client udp", lens: .application).isEmpty)
    #expect(MonitorQuery.filter(
        [row], search: "", lens: .application, decision: .denied
    ).count == 1)
    #expect(MonitorQuery.filter(
        [row], search: "", lens: .application, decision: .allowed
    ).isEmpty)
    #expect(MonitorQuery.filter(
        [row], search: "", lens: .application, direction: .incoming
    ).isEmpty)
    #expect(MonitorQuery.filter(
        [row], search: "", lens: .application, time: .hour,
        now: event.occurredAt.addingTimeInterval(3_601)
    ).isEmpty)
    let locationRows = MonitorQuery.filter(
        [row], search: "los angeles california", lens: .location,
        geography: geography
    )
    #expect(locationRows.first?.primary.contains("Los Angeles, United States") == true)
    #expect(MonitorQuery.filter(
        [row], search: "france", lens: .location, geography: geography
    ).isEmpty)
}

@Test func monitorSortsUseAStableEventIdentifierTieBreak() throws {
    let first = try monitorQueryRow(hostname: "same.example.test")
    let second = try monitorQueryRow(hostname: "same.example.test")
    let input = [second, first]
    let expected = input.map(\.id).sorted()

    for sort in MonitorSort.allCases {
        let result = MonitorQuery.filter(
            input, search: "", lens: .application, sort: sort
        )
        #expect(result.map(\.id) == expected)
    }
}

@Test func monitorSearchSupportsQuotedPhrasesAndExplicitFields() throws {
    let row = try detailedMonitorQueryRow()
    let location = try GeoLocation(
        continentCode: "NA", countryCode: "US", region: "California",
        city: "Los Angeles", latitude: 34.05, longitude: -118.24
    )
    let geography = [row.id: GeoResolution.located(location)]
    let query = """
        app:com.example.client process:com.example.helper host:API.EXAMPLE.TEST. \
        ip:2001:0db8:0:0:0:0:0:10 port:443 decision:denied direction:outgoing \
        \"los angeles\"
        """

    #expect(MonitorQuery.filter(
        [row], search: query, lens: .application, geography: geography
    ).map(\.id) == [row.id])
    #expect(MonitorQuery.filter(
        [row], search: "host:example.test", lens: .application
    ).isEmpty)
    #expect(MonitorQuery.filter(
        [row], search: "host:bücher.example", lens: .application
    ).isEmpty)
    let asciiLookalike = try detailedMonitorQueryRow(hostname: "bucher.example")
    #expect(MonitorQuery.filter(
        [asciiLookalike], search: "host:bücher.example", lens: .application
    ).isEmpty)
    #expect(MonitorQuery.filter(
        [row], search: "ip:2001:db8::11", lens: .application
    ).isEmpty)
}

@Test func monitorSearchMalformedAndUnknownFieldsStayLiteral() throws {
    let row = try detailedMonitorQueryRow()
    let literalQueries = [
        "unknown:client",
        "app:\"client",
        "ip:not-an-ip",
        "port:70000",
        "decision:maybe",
        "direction:sideways",
    ]
    for query in literalQueries {
        let parsed = MonitorSearchQuery(query)
        #expect(!parsed.isRejected)
        #expect(parsed.tokenCount == 1)
        #expect(MonitorQuery.filter([row], search: query, lens: .application).isEmpty)
    }
}

@Test func monitorSearchCapsInputTokensAndIndividualTerms() throws {
    let row = try detailedMonitorQueryRow()
    let oversized = String(repeating: "x", count: MonitorSearchQuery.maximumInputScalars + 1)
    let overlongToken = String(repeating: "x", count: MonitorSearchQuery.maximumTokenScalars + 1)
    let tooManyTokens = Array(
        repeating: "client",
        count: MonitorSearchQuery.maximumTokens + 1
    ).joined(separator: " ")
    for query in [oversized, overlongToken, tooManyTokens] {
        #expect(MonitorSearchQuery(query).isRejected)
        #expect(MonitorQuery.filter([row], search: query, lens: .application).isEmpty)
    }
    #expect(!MonitorSearchQuery("CLIENT deny").isRejected)
    #expect(MonitorQuery.filter(
        [row], search: "CLIENT deny", lens: .application
    ).map(\.id) == [row.id])
}

@Test func monitorQueryEvaluationChecksCancellationDuringRows() throws {
    let row = try detailedMonitorQueryRow()
    var checks = 0
    #expect(throws: MonitorQueryTestError.cancelled) {
        try MonitorQuery.filter(
            Array(repeating: row, count: 256),
            search: "client",
            lens: .application,
            decision: .all,
            direction: .all,
            time: .all,
            sort: .recent,
            geography: [:],
            now: Date(),
            cancellationCheck: {
                checks += 1
                if checks == 3 { throw MonitorQueryTestError.cancelled }
            }
        )
    }
    #expect(checks == 3)
}

@Test func detachedMonitorWorkerPropagatesOuterCancellation() async {
    let gate = MonitorQueryWorkerGate()
    let task = Task {
        try await MonitorQueryWorker.run {
            await gate.signalStarted()
            try await Task.sleep(for: .seconds(2))
            return true
        }
    }
    await gate.waitUntilStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func monitorQueryPublicationRejectsStaleAndCancelledRequests() throws {
    let staleValue = try #require(
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")
    )
    let activeValue = try #require(
        UUID(uuidString: "22222222-2222-2222-2222-222222222222")
    )
    let stale = MonitorQueryRequestID(
        value: staleValue
    )
    let active = MonitorQueryRequestID(
        value: activeValue
    )
    #expect(!MonitorQueryPublication.permits(
        stale, active: active, taskIsCancelled: false
    ))
    #expect(MonitorQueryPublication.permits(
        active, active: active, taskIsCancelled: false
    ))
    #expect(!MonitorQueryPublication.permits(
        active, active: active, taskIsCancelled: true
    ))
}

private func monitorQueryRow(hostname: String?) throws -> MonitorEventRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let host = try hostname.map(DomainName.init)
    var confidence: MetadataConfidence = [.appIdentity, .endpoint]
    if host != nil { confidence.insert(.observedHostname) }
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(timeIntervalSince1970: 1_000),
        sourceAppIdentity: identity, sourceProcessIdentity: identity,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("203.0.113.10"), port: 443,
            hostname: host, hostnameCoverage: host == nil ? .absent : .observed,
            classes: [], interfaceSnapshotGeneration: 1
        ),
        observedHostname: host, metadataConfidence: confidence
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: flow.observedAt,
            flow: flow, action: .allow, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete
    )
}

private func detailedMonitorQueryRow(
    hostname hostnameValue: String = "api.example.test"
) throws -> MonitorEventRow {
    let app = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "com.example.Client")
    )
    let process = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "com.example.Helper")
    )
    let hostname = try DomainName(hostnameValue)
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(timeIntervalSince1970: 2_000),
        sourceAppIdentity: app, sourceProcessIdentity: process,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("2001:db8::10"), port: 443,
            hostname: hostname, hostnameCoverage: .observed,
            classes: [], interfaceSnapshotGeneration: 1
        ),
        observedHostname: hostname,
        metadataConfidence: [.appIdentity, .processIdentity, .endpoint, .observedHostname]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: flow.observedAt,
            flow: flow, action: .deny, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete
    )
}

private enum MonitorQueryTestError: Error {
    case cancelled
}

private actor MonitorQueryWorkerGate {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signalStarted() {
        started = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
