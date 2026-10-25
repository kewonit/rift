import Darwin
import Foundation

public enum IPAddressError: Error, Sendable, Equatable {
    case invalidAddress(String)
}

public struct IPAddress: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public enum Family: UInt8, Sendable, Codable, Comparable {
        case ipv4 = 4
        case ipv6 = 6

        public static func < (lhs: Family, rhs: Family) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let family: Family
    private let storage: [UInt8]

    public init(_ text: String) throws {
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            family = .ipv4
            storage = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }

        var v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
                family = .ipv4
                storage = Array(bytes[12..<16])
            } else {
                family = .ipv6
                storage = bytes
            }
            return
        }
        throw IPAddressError.invalidAddress(text)
    }

    init(family: Family, bytes: [UInt8]) {
        precondition(bytes.count == (family == .ipv4 ? 4 : 16))
        self.family = family
        self.storage = bytes
    }

    public var bytes: [UInt8] { storage }
    public var bitWidth: Int { storage.count * 8 }

    public var description: String {
        switch family {
        case .ipv4:
            storage.map(String.init).joined(separator: ".")
        case .ipv6:
            Self.formatIPv6(storage)
        }
    }

    public static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        if lhs.family != rhs.family { return lhs.family < rhs.family }
        return lhs.storage.lexicographicallyPrecedes(rhs.storage)
    }

    func masked(prefixLength: Int) -> IPAddress {
        var result = storage
        for bit in prefixLength..<bitWidth {
            result[bit / 8] &= ~(1 << (7 - bit % 8))
        }
        return IPAddress(family: family, bytes: result)
    }

    func upperBound(prefixLength: Int) -> IPAddress {
        var result = masked(prefixLength: prefixLength).storage
        for bit in prefixLength..<bitWidth {
            result[bit / 8] |= 1 << (7 - bit % 8)
        }
        return IPAddress(family: family, bytes: result)
    }

    func distanceMagnitude(to upper: IPAddress) -> [UInt8] {
        precondition(family == upper.family && self <= upper)
        var result = Array(repeating: UInt8(0), count: storage.count)
        var borrow = 0
        for index in storage.indices.reversed() {
            var value = Int(upper.storage[index]) - Int(storage[index]) - borrow
            if value < 0 {
                value += 256
                borrow = 1
            } else {
                borrow = 0
            }
            result[index] = UInt8(value)
        }
        return result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do {
            try self.init(text)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid IP address: \(text)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func formatIPv6(_ bytes: [UInt8]) -> String {
        let words = stride(from: 0, to: 16, by: 2).map {
            UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])
        }
        var bestStart: Int?
        var bestLength = 0
        var cursor = 0
        while cursor < words.count {
            guard words[cursor] == 0 else {
                cursor += 1
                continue
            }
            let start = cursor
            while cursor < words.count, words[cursor] == 0 { cursor += 1 }
            let length = cursor - start
            if length >= 2, length > bestLength {
                bestStart = start
                bestLength = length
            }
        }

        if let bestStart {
            let left = words[..<bestStart].map { String($0, radix: 16) }.joined(separator: ":")
            let rightStart = bestStart + bestLength
            let right = words[rightStart...].map { String($0, radix: 16) }.joined(separator: ":")
            return left + "::" + right
        }
        return words.map { String($0, radix: 16) }.joined(separator: ":")
    }
}
