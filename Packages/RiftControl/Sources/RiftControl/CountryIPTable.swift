import Foundation
import RiftCore

/// Maps public IP addresses to the country that routes them. Lookups run only on
/// the Mac; the table is bundled with the app.
public struct CountryIPTable: Sendable {
    private let codes: [String]
    private let ipv4Starts: [UInt32]
    private let ipv4Countries: [UInt8]
    private let ipv6Starts: [UInt64]
    private let ipv6Countries: [UInt8]

    public init(compressedData: Data) throws {
        var reader = NetworkDataReader(try NetworkDataReader.inflate(compressedData))
        try reader.expect("RIFTIPC1")
        let ipv4Count = Int(try reader.uint32())
        let ipv6Count = Int(try reader.uint32())
        let codeCount = Int(try reader.uint8())
        let codes = [""] + (try reader.countryCodes(codeCount))

        var ipv4Starts: [UInt32] = []
        ipv4Starts.reserveCapacity(ipv4Count)
        var value: UInt64 = 0
        for _ in 0..<ipv4Count {
            value += try reader.varint()
            guard value <= UInt64(UInt32.max) else { throw NetworkDataError.invalidFormat }
            ipv4Starts.append(UInt32(value))
        }
        let ipv4Countries = try reader.take(ipv4Count)

        var ipv6Starts: [UInt64] = []
        ipv6Starts.reserveCapacity(ipv6Count)
        value = 0
        for _ in 0..<ipv6Count {
            let (sum, overflow) = value.addingReportingOverflow(try reader.varint())
            guard !overflow else { throw NetworkDataError.invalidFormat }
            value = sum
            ipv6Starts.append(value)
        }
        let ipv6Countries = try reader.take(ipv6Count)

        let codeLimit = codes.count
        guard ipv4Countries.allSatisfy({ Int($0) < codeLimit }),
              ipv6Countries.allSatisfy({ Int($0) < codeLimit }) else {
            throw NetworkDataError.invalidFormat
        }
        self.codes = codes
        self.ipv4Starts = ipv4Starts
        self.ipv4Countries = ipv4Countries
        self.ipv6Starts = ipv6Starts
        self.ipv6Countries = ipv6Countries
    }

    /// The ISO 3166-1 alpha-2 code for a public address, or nil when unknown.
    public func countryCode(for address: IPAddress) -> String? {
        let bytes = address.bytes
        let index: UInt8?
        switch address.family {
        case .ipv4:
            let value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            index = Self.lookup(value, in: ipv4Starts).map { ipv4Countries[$0] }
        case .ipv6:
            let value = bytes.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            index = Self.lookup(value, in: ipv6Starts).map { ipv6Countries[$0] }
        }
        guard let index, index > 0 else { return nil }
        return codes[Int(index)]
    }

    private static func lookup<Value: Comparable>(_ value: Value, in starts: [Value]) -> Int? {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }
}
