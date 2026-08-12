public enum IPIntervalError: Error, Sendable, Equatable {
    case invalidPrefix(Int, addressBits: Int)
    case mixedFamilies
    case reversedRange
}

public struct IPInterval: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let lowerBound: IPAddress
    public let upperBound: IPAddress

    public init(exact address: IPAddress) {
        lowerBound = address
        upperBound = address
    }

    public init(cidr address: IPAddress, prefixLength: Int) throws {
        guard (0...address.bitWidth).contains(prefixLength) else {
            throw IPIntervalError.invalidPrefix(prefixLength, addressBits: address.bitWidth)
        }
        lowerBound = address.masked(prefixLength: prefixLength)
        upperBound = address.upperBound(prefixLength: prefixLength)
    }

    public init(range lowerBound: IPAddress, _ upperBound: IPAddress) throws {
        guard lowerBound.family == upperBound.family else {
            throw IPIntervalError.mixedFamilies
        }
        guard lowerBound <= upperBound else { throw IPIntervalError.reversedRange }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    public func contains(_ address: IPAddress) -> Bool {
        address.family == lowerBound.family && lowerBound <= address && address <= upperBound
    }

    var spanMagnitude: [UInt8] {
        lowerBound.distanceMagnitude(to: upperBound)
    }

    public var description: String {
        lowerBound == upperBound ? lowerBound.description : "\(lowerBound)-\(upperBound)"
    }

    public static func < (lhs: IPInterval, rhs: IPInterval) -> Bool {
        if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
        return lhs.upperBound < rhs.upperBound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lowerBound = try container.decode(IPAddress.self, forKey: .lowerBound)
        let upperBound = try container.decode(IPAddress.self, forKey: .upperBound)
        do {
            try self.init(range: lowerBound, upperBound)
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid IP interval: \(error)",
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
