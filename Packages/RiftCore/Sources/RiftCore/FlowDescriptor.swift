import Foundation

public enum TrafficDirection: String, Sendable, Codable {
    case incoming
    case outgoing
}

public enum TransportProtocol: Sendable, Hashable, Codable {
    case tcp
    case udp
    case unsupported(number: UInt8)
}

public enum HostnameCoverage: String, Sendable, Codable {
    case observed
    case unavailableForClient
    case absent
}

public enum EndpointClass: String, Sendable, Hashable, Codable, CaseIterable {
    case loopback
    case linkLocal
    case broadcast
    case multicast
    case bonjour
    case localNetwork
}

public struct Endpoint: Sendable, Hashable, Codable {
    public let address: IPAddress
    public let port: UInt16?
    public let hostname: DomainName?
    public let hostnameCoverage: HostnameCoverage
    public let classes: Set<EndpointClass>
    public let interfaceSnapshotGeneration: UInt64

    public init(
        address: IPAddress,
        port: UInt16?,
        hostname: DomainName?,
        hostnameCoverage: HostnameCoverage,
        classes: Set<EndpointClass>,
        interfaceSnapshotGeneration: UInt64
    ) {
        self.address = address
        self.port = port
        self.hostname = hostname
        self.hostnameCoverage = hostnameCoverage
        self.classes = classes
        self.interfaceSnapshotGeneration = interfaceSnapshotGeneration
    }
}

public enum FlowOwner: Sendable, Hashable, Codable {
    case user(uid: UInt32)
    case system
    case unknown
}

public struct MetadataConfidence: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let appIdentity = MetadataConfidence(rawValue: 1 << 0)
    public static let processIdentity = MetadataConfidence(rawValue: 1 << 1)
    public static let endpoint = MetadataConfidence(rawValue: 1 << 2)
    public static let observedHostname = MetadataConfidence(rawValue: 1 << 3)
    public static let owner = MetadataConfidence(rawValue: 1 << 4)
}

public struct FlowDescriptor: Sendable, Hashable, Codable {
    public static let schemaVersion: UInt16 = 1

    public let flowID: UUID
    public let observedAt: Date
    public let sourceAppIdentity: ProcessIdentity?
    public let sourceProcessIdentity: ProcessIdentity?
    public let owner: FlowOwner
    public let direction: TrafficDirection
    public let transportProtocol: TransportProtocol
    public let localEndpoint: Endpoint?
    public let remoteEndpoint: Endpoint?
    public let observedHostname: DomainName?
    public let metadataConfidence: MetadataConfidence

    public init(
        flowID: UUID,
        observedAt: Date,
        sourceAppIdentity: ProcessIdentity?,
        sourceProcessIdentity: ProcessIdentity?,
        owner: FlowOwner,
        direction: TrafficDirection,
        transportProtocol: TransportProtocol,
        localEndpoint: Endpoint?,
        remoteEndpoint: Endpoint?,
        observedHostname: DomainName?,
        metadataConfidence: MetadataConfidence
    ) {
        self.flowID = flowID
        self.observedAt = observedAt
        self.sourceAppIdentity = sourceAppIdentity
        self.sourceProcessIdentity = sourceProcessIdentity
        self.owner = owner
        self.direction = direction
        self.transportProtocol = transportProtocol
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.observedHostname = observedHostname
        self.metadataConfidence = metadataConfidence
    }

    public var destinationEndpoint: Endpoint? {
        direction == .outgoing ? remoteEndpoint : localEndpoint
    }
}
