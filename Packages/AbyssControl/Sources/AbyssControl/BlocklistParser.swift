import AbyssCore
import CryptoKit
import Foundation

public enum BlocklistEntry: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    case domain(DomainName)
    case address(IPInterval)

    public var description: String {
        switch self {
        case .domain(let value): value.description
        case .address(let value): value.description
        }
    }

    public static func < (lhs: BlocklistEntry, rhs: BlocklistEntry) -> Bool {
        switch (lhs, rhs) {
        case (.domain(let left), .domain(let right)): left < right
        case (.address(let left), .address(let right)): left < right
        case (.domain, .address): true
        case (.address, .domain): false
        }
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard values.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "A blocklist entry must contain exactly one supported value."
            ))
        }
        if values.contains(.domain) {
            self = .domain(try values.decode(DomainName.self, forKey: .domain))
        } else {
            self = .address(try values.decode(IPInterval.self, forKey: .address))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .domain(let value): try values.encode(value, forKey: .domain)
        case .address(let value): try values.encode(value, forKey: .address)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case address
    }
}

public enum BlocklistParserError: Error, Sendable, Equatable {
    case oversizedInput
    case tooManyEntries
    case lineTooLong
    case malformedLine(Int)
    case empty
}

struct BlocklistParseMetrics: Sendable, Equatable {
    let inputBytes: Int
    let maximumBufferedLineBytes: Int
    let uniqueEntryHighWater: Int
}

struct BlocklistParseOutput: Sendable {
    let entries: [BlocklistEntry]
    let contentHash: Data
    let metrics: BlocklistParseMetrics
}

public enum BlocklistParser {
    public static let maximumBytes = 8 * 1_024 * 1_024
    public static let maximumEntries = 200_000
    public static let maximumLineBytes = 4_096
    static let inputChunkBytes = 64 * 1_024

    public static func parse(_ data: Data) throws -> [BlocklistEntry] {
        try parseInstrumented(data).entries
    }

    static func parseInstrumented(
        _ data: Data,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> BlocklistParseOutput {
        try cancellationCheck()
        guard data.count <= maximumBytes else { throw BlocklistParserError.oversizedInput }
        let contentStart = hasUTF8BOM(data) ? 3 : 0
        var parser = BlocklistLineParser()
        var hasher = SHA256()
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try cancellationCheck()
                let upper = min(offset + inputChunkBytes, bytes.count)
                let hashChunk = UnsafeRawBufferPointer(rebasing: bytes[offset..<upper])
                hasher.update(bufferPointer: hashChunk)
                let parseStart = max(offset, contentStart)
                if parseStart < upper {
                    try parser.consume(
                        UnsafeRawBufferPointer(rebasing: bytes[parseStart..<upper]),
                        cancellationCheck: cancellationCheck
                    )
                }
                offset = upper
            }
        }
        try cancellationCheck()
        let entries = try parser.finish(cancellationCheck: cancellationCheck)
        return BlocklistParseOutput(
            entries: entries,
            contentHash: Data(hasher.finalize()),
            metrics: BlocklistParseMetrics(
                inputBytes: data.count,
                maximumBufferedLineBytes: parser.maximumBufferedLineBytes,
                uniqueEntryHighWater: parser.uniqueEntryHighWater
            )
        )
    }

    private static func hasUTF8BOM(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let start = data.startIndex
        return data[start] == 0xEF && data[data.index(after: start)] == 0xBB
            && data[data.index(start, offsetBy: 2)] == 0xBF
    }
}

private struct BlocklistLineParser {
    private var line: [UInt8] = []
    private var entries: Set<BlocklistEntry> = []
    private var lineNumber = 1
    private var previousWasCarriageReturn = false
    private var bytesSinceCancellationCheck = 0
    private(set) var maximumBufferedLineBytes = 0
    private(set) var uniqueEntryHighWater = 0

    init() {
        line.reserveCapacity(BlocklistParser.maximumLineBytes + 3)
    }

    mutating func consume(
        _ bytes: UnsafeRawBufferPointer,
        cancellationCheck: () throws -> Void
    ) throws {
        for byte in bytes {
            bytesSinceCancellationCheck += 1
            if bytesSinceCancellationCheck >= BlocklistParser.maximumLineBytes {
                try cancellationCheck()
                bytesSinceCancellationCheck = 0
            }
            if previousWasCarriageReturn {
                previousWasCarriageReturn = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0D:
                try emitLine(cancellationCheck: cancellationCheck)
                previousWasCarriageReturn = true
            case 0x0A, 0x0B, 0x0C:
                try emitLine(cancellationCheck: cancellationCheck)
            default:
                try append(byte, cancellationCheck: cancellationCheck)
            }
        }
    }

    mutating func finish(
        cancellationCheck: () throws -> Void
    ) throws -> [BlocklistEntry] {
        try cancellationCheck()
        try parseCurrentLine(cancellationCheck: cancellationCheck)
        guard !entries.isEmpty else { throw BlocklistParserError.empty }
        var result = Array(entries)
        entries.removeAll(keepingCapacity: false)
        result.sort()
        return result
    }

    private mutating func append(
        _ byte: UInt8,
        cancellationCheck: () throws -> Void
    ) throws {
        guard line.count < BlocklistParser.maximumLineBytes + 3 else {
            throw BlocklistParserError.lineTooLong
        }
        line.append(byte)
        maximumBufferedLineBytes = max(maximumBufferedLineBytes, line.count)
        if line.count >= 2,
           line[line.count - 2] == 0xC2, line[line.count - 1] == 0x85 {
            line.removeLast(2)
            try emitLine(cancellationCheck: cancellationCheck)
        } else if line.count >= 3,
                  line[line.count - 3] == 0xE2, line[line.count - 2] == 0x80,
                  (line[line.count - 1] == 0xA8 || line[line.count - 1] == 0xA9) {
            line.removeLast(3)
            try emitLine(cancellationCheck: cancellationCheck)
        }
    }

    private mutating func emitLine(
        cancellationCheck: () throws -> Void
    ) throws {
        try parseCurrentLine(cancellationCheck: cancellationCheck)
        line.removeAll(keepingCapacity: true)
        lineNumber += 1
    }

    private mutating func parseCurrentLine(
        cancellationCheck: () throws -> Void
    ) throws {
        try cancellationCheck()
        guard line.count <= BlocklistParser.maximumLineBytes else {
            throw BlocklistParserError.lineTooLong
        }
        guard let text = String(bytes: line, encoding: .utf8) else {
            throw BlocklistParserError.malformedLine(lineNumber)
        }
        let comment = text.firstIndex(of: "#") ?? text.endIndex
        let fields = text[..<comment].split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard !fields.isEmpty else { return }
        let candidates: ArraySlice<Substring>
        if fields.count > 1,
           (try? IPAddress(String(fields[0]))) != nil,
           fields.dropFirst().allSatisfy({ (try? DomainName(String($0))) != nil }) {
            candidates = fields.dropFirst()
        } else {
            candidates = fields[...]
        }
        for candidate in candidates {
            try cancellationCheck()
            guard let entry = try parseToken(String(candidate)) else {
                throw BlocklistParserError.malformedLine(lineNumber)
            }
            if entries.count == BlocklistParser.maximumEntries,
               !entries.contains(entry) {
                throw BlocklistParserError.tooManyEntries
            }
            entries.insert(entry)
            uniqueEntryHighWater = max(uniqueEntryHighWater, entries.count)
        }
    }

    private func parseToken(_ token: String) throws -> BlocklistEntry? {
        if token.contains("/") {
            let parts = token.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let address = try? IPAddress(String(parts[0])),
                  let prefix = Int(parts[1]),
                  let interval = try? IPInterval(cidr: address, prefixLength: prefix) else {
                return nil
            }
            return .address(interval)
        }
        if let address = try? IPAddress(token) { return .address(IPInterval(exact: address)) }
        if token.contains("-") {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            if parts.count == 2,
               let lower = try? IPAddress(String(parts[0])),
               let upper = try? IPAddress(String(parts[1])) {
                guard let interval = try? IPInterval(range: lower, upper) else { return nil }
                return .address(interval)
            }
        }
        if let domain = try? DomainName(token) { return .domain(domain) }
        return nil
    }
}
