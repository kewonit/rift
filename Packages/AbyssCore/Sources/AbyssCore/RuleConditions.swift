import Foundation

public struct PortRange: Sendable, Hashable, Comparable, Codable {
    public let lowerBound: UInt16
    public let upperBound: UInt16

    public init(_ lowerBound: UInt16, _ upperBound: UInt16) throws {
        guard lowerBound != 0 else { throw PortRangeError.zeroPort }
        guard lowerBound <= upperBound else { throw PortRangeError.reversedRange }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public func contains(_ port: UInt16) -> Bool {
        (lowerBound...upperBound).contains(port)
    }

    public var span: UInt16 { upperBound - lowerBound }

    public static func < (lhs: PortRange, rhs: PortRange) -> Bool {
        if lhs.span != rhs.span { return lhs.span < rhs.span }
        return lhs.lowerBound < rhs.lowerBound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lowerBound = try container.decode(UInt16.self, forKey: .lowerBound)
        let upperBound = try container.decode(UInt16.self, forKey: .upperBound)
        do {
            try self.init(lowerBound, upperBound)
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid port range: \(error)",
                underlyingError: error
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lowerBound, forKey: .lowerBound)
        try container.encode(upperBound, forKey: .upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case lowerBound
        case upperBound
    }
}

public enum PortRangeError: Error, Sendable, Equatable {
    case zeroPort
    case reversedRange
}

public enum ProtocolCondition: Sendable, Hashable, Codable {
    case tcp
    case udp
    case anySupportedProtocol
}

public enum ProcessCondition: Sendable, Hashable, Codable {
    case anyProcess
    case exact(ProcessIdentity)
    case appViaHelper(app: ProcessIdentity, helper: ProcessIdentity)
}

public enum OwnerCondition: Sendable, Hashable, Codable {
    case authorizedUser
    case specificUser(uid: UInt32)
    case system
}

public enum DirectionCondition: String, Sendable, Hashable, Codable {
    case incoming
    case outgoing
    case bidirectional
}

public enum DestinationConditionError: Error, Sendable, Equatable {
    case empty
    case overLimit(Int)
    case nonCanonical
}

public enum DestinationCondition: Sendable, Hashable, Codable {
    case ipSet([IPInterval])
    case exactHostnameSet([DomainName])
    case domainSet([DomainName])
    case endpointClass(EndpointClass)
    case anyEndpoint

    public static func normalizedIPSet(_ values: [IPInterval]) throws -> DestinationCondition {
        .ipSet(try normalized(values))
    }

    public static func normalizedExactHostnameSet(_ values: [DomainName]) throws -> DestinationCondition {
        .exactHostnameSet(try normalized(values))
    }

    public static func normalizedDomainSet(_ values: [DomainName]) throws -> DestinationCondition {
        .domainSet(try normalized(values))
    }

    public var memberCount: Int {
        switch self {
        case .ipSet(let values): values.count
        case .exactHostnameSet(let values), .domainSet(let values): values.count
        case .endpointClass, .anyEndpoint: 1
        }
    }

    public func validated() throws -> DestinationCondition {
        switch self {
        case .ipSet(let values): try .normalizedIPSet(values)
        case .exactHostnameSet(let values): try .normalizedExactHostnameSet(values)
        case .domainSet(let values): try .normalizedDomainSet(values)
        case .endpointClass, .anyEndpoint: self
        }
    }

    private static func normalized<Value: Hashable & Comparable>(_ values: [Value]) throws -> [Value] {
        let result = Array(Set(values)).sorted()
        guard !result.isEmpty else { throw DestinationConditionError.empty }
        guard result.count <= PolicyLimits.maximumDestinationMembers else {
            throw DestinationConditionError.overLimit(result.count)
        }
        return result
    }
}
