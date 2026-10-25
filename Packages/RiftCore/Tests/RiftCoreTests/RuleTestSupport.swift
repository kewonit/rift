import Foundation
@testable import RiftCore

enum RuleTestSupport {
    static let now = Date(timeIntervalSince1970: 1_750_000_000)
    static let appIdentity: ProcessIdentity = {
        let signed = try? SignedCodeIdentity(
            teamIdentifier: "TESTTEAM01",
            signingIdentifier: "io.rift.fixture.app"
        )
        guard let signed else { preconditionFailure("Static test identity is invalid") }
        return .developerID(signed)
    }()
    static let helperIdentity: ProcessIdentity = {
        let signed = try? SignedCodeIdentity(
            teamIdentifier: "TESTTEAM01",
            signingIdentifier: "io.rift.fixture.helper"
        )
        guard let signed else { preconditionFailure("Static test identity is invalid") }
        return .developerID(signed)
    }()

    static func uuid(_ value: UInt64) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            UInt8(truncatingIfNeeded: value >> 56),
            UInt8(truncatingIfNeeded: value >> 48),
            UInt8(truncatingIfNeeded: value >> 40),
            UInt8(truncatingIfNeeded: value >> 32),
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value)
        ))
    }

    static func endpoint(
        address: String = "203.0.113.7",
        port: UInt16? = 443,
        hostname: String? = "api.example.com",
        classes: Set<EndpointClass> = []
    ) throws -> Endpoint {
        Endpoint(
            address: try IPAddress(address),
            port: port,
            hostname: try hostname.map(DomainName.init),
            hostnameCoverage: hostname == nil ? .absent : .observed,
            classes: classes,
            interfaceSnapshotGeneration: 1
        )
    }

    static func flow(
        id: UInt64 = 1,
        app: ProcessIdentity? = appIdentity,
        process: ProcessIdentity? = appIdentity,
        owner: FlowOwner = .user(uid: 501),
        direction: TrafficDirection = .outgoing,
        transport: TransportProtocol = .tcp,
        local: Endpoint? = nil,
        remote: Endpoint? = nil,
        observedHostname: DomainName?? = nil
    ) throws -> FlowDescriptor {
        let defaultRemote = try endpoint()
        let selectedRemote = remote ?? defaultRemote
        let selectedHost: DomainName?
        if let observedHostname {
            selectedHost = observedHostname
        } else {
            selectedHost = selectedRemote.hostname
        }
        return FlowDescriptor(
            flowID: uuid(id),
            observedAt: now,
            sourceAppIdentity: app,
            sourceProcessIdentity: process,
            owner: owner,
            direction: direction,
            transportProtocol: transport,
            localEndpoint: local,
            remoteEndpoint: selectedRemote,
            observedHostname: selectedHost,
            metadataConfidence: [.appIdentity, .processIdentity, .endpoint, .owner]
        )
    }

    static func rule(
        id: UInt64,
        action: RuleAction,
        lineageID: UUID = uuid(99),
        priority: RulePriority = .normal,
        process: ProcessCondition = .anyProcess,
        destination: DestinationCondition = .anyEndpoint,
        transport: ProtocolCondition = .anySupportedProtocol,
        port: PortRange? = nil,
        direction: DirectionCondition = .bidirectional,
        owner: OwnerCondition = .authorizedUser,
        profileID: UUID? = nil,
        groupID: UUID? = nil,
        expiresAt: Date? = nil,
        flags: RuleFlags = [],
        reviewState: RuleReviewState = .reviewed,
        source: RuleSource = .manual
    ) throws -> Rule {
        try Rule(
            id: uuid(id),
            lineageID: lineageID,
            revision: 1,
            action: action,
            priority: priority,
            process: process,
            destination: destination,
            transportProtocol: transport,
            port: port,
            direction: direction,
            owner: owner,
            profileID: profileID,
            localGroupID: groupID,
            expiresAt: expiresAt,
            flags: flags,
            reviewState: reviewState,
            source: source,
            createdAt: now,
            modifiedAt: now
        )
    }

    static func context(
        activeProfileID: UUID? = nil,
        enabledGroups: Set<UUID> = [],
        expiryMetadata: ExpiryMetadata = .available(alreadyExpired: [])
    ) -> MatchContext {
        MatchContext(
            activeProfileID: activeProfileID,
            enabledLocalGroupIDs: enabledGroups,
            authorizedUID: 501,
            policyTime: PolicyTime(now: now, expiryMetadata: expiryMetadata)
        )
    }
}

struct DeterministicGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func index(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}
