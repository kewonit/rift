import RiftCore
import CryptoKit
import Foundation

/// One entry in a blocklist. Hosts files block exact names; a plain list of
/// names, `*.name` and Adblock's `||name^` block each name and every name
/// under it.
public enum BlocklistEntry: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    case domain(DomainName)
    case address(IPInterval)
    case domainAndSubdomains(DomainName)

    public var description: String {
        switch self {
        case .domain(let value): value.description
        case .address(let value): value.description
        case .domainAndSubdomains(let value): "*." + value.description
        }
    }

    /// The name this entry blocks, with or without the names under it.
    public var name: DomainName? {
        switch self {
        case .domain(let value), .domainAndSubdomains(let value): value
        case .address: nil
        }
    }

    /// Whether a connection to `host` is blocked by this entry.
    public func covers(_ host: DomainName) -> Bool {
        switch self {
        case .domain(let value): host == value
        case .domainAndSubdomains(let value): host.isEqualToOrSubdomain(of: value)
        case .address: false
        }
    }

    private var rank: Int {
        switch self {
        case .domain: 0
        case .domainAndSubdomains: 1
        case .address: 2
        }
    }

    public static func < (lhs: BlocklistEntry, rhs: BlocklistEntry) -> Bool {
        switch (lhs, rhs) {
        case (.domain(let left), .domain(let right)): left < right
        case (.domainAndSubdomains(let left), .domainAndSubdomains(let right)): left < right
        case (.address(let left), .address(let right)): left < right
        default: lhs.rank < rhs.rank
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
        } else if values.contains(.domainAndSubdomains) {
            self = .domainAndSubdomains(try values.decode(DomainName.self, forKey: .domainAndSubdomains))
        } else {
            self = .address(try values.decode(IPInterval.self, forKey: .address))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .domain(let value): try values.encode(value, forKey: .domain)
        case .address(let value): try values.encode(value, forKey: .address)
        case .domainAndSubdomains(let value): try values.encode(value, forKey: .domainAndSubdomains)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case domain
        case address
        case domainAndSubdomains
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
        let trimmed = text.drop(while: \.isWhitespace)
        if let adblock = BlocklistAdblockLine(trimmed) {
            guard case .name(let name) = adblock else { return }
            try insert(.domainAndSubdomains(name))
            return
        }
        let comment = text.firstIndex(where: { $0 == "#" || $0 == ";" }) ?? text.endIndex
        let fields = text[..<comment].split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard !fields.isEmpty else { return }
        let candidates: ArraySlice<Substring>
        let hostsLine: Bool
        if fields.count > 1,
           (try? IPAddress(String(fields[0]))) != nil,
           fields.dropFirst().allSatisfy({ (try? DomainName(String($0))) != nil }) {
            candidates = fields.dropFirst()
            hostsLine = true
        } else {
            candidates = fields[...]
            hostsLine = false
        }
        for candidate in candidates {
            try cancellationCheck()
            guard var entry = try parseToken(String(candidate)) else {
                throw BlocklistParserError.malformedLine(lineNumber)
            }
            // A hosts file maps exact names; a plain list means each name
            // and the names under it.
            if !hostsLine, case .domain(let name) = entry { entry = .domainAndSubdomains(name) }
            try insert(entry)
        }
    }

    private mutating func insert(_ entry: BlocklistEntry) throws {
        if entries.count == BlocklistParser.maximumEntries,
           !entries.contains(entry) {
            throw BlocklistParserError.tooManyEntries
        }
        entries.insert(entry)
        uniqueEntryHighWater = max(uniqueEntryHighWater, entries.count)
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

/// The part of Adblock filter syntax a name list can use. `||name^` blocks a
/// name and its subdomains, as does a wildcard list's `*.name`; comments, the header, exceptions, element-hiding rules, and rules
/// with options or paths are skipped, because Rift can't apply them. Blocking
/// a name an option limits, such as `$third-party`, would block more than the
/// list means.
enum BlocklistAdblockLine: Equatable {
    case name(DomainName)
    case skipped

    init?(_ line: Substring) {
        if line.hasPrefix("!") || line.hasPrefix("[") || line.hasPrefix("@@") {
            self = .skipped
            return
        }
        // An element-hiding rule puts its marker right after the names, with
        // no space; a hosts file comment has a space before it.
        for marker in ["##", "#@#", "#?#", "#$#", "#%#"] {
            if let range = line.range(of: marker),
               !line[..<range.lowerBound].contains(where: \.isWhitespace) {
                self = .skipped
                return
            }
        }
        // `*.name`, as wildcard name lists write a name and its subdomains.
        if line.hasPrefix("*.") {
            let body = line.dropFirst(2).prefix { !$0.isWhitespace }
            let rest = line.dropFirst(2 + body.count).drop(while: \.isWhitespace)
            if rest.isEmpty || rest.hasPrefix("#") || rest.hasPrefix(";"),
               let name = try? DomainName(String(body)) {
                self = .name(name)
            } else {
                self = .skipped
            }
            return
        }
        guard line.hasPrefix("||") else {
            if Self.usesAdblockOnlySyntax(line) {
                self = .skipped
                return
            }
            return nil
        }
        let body = line.dropFirst(2).prefix { !$0.isWhitespace }
        guard body.hasSuffix("^"), let name = try? DomainName(String(body.dropLast())) else {
            self = .skipped
            return
        }
        self = .name(name)
    }

    /// Characters and starts that only Adblock rules use, such as `/ads/*`,
    /// `-banner.`, `|https://`, or `&ad_type=`. A hosts file or name list
    /// never has them, though an address range like `203.0.113.0/24` has a
    /// slash, so a slash alone doesn't count.
    private static func usesAdblockOnlySyntax(_ line: Substring) -> Bool {
        let token = line.prefix { !$0.isWhitespace }
        if let first = token.first, "/|-._:?=&*".contains(first) { return true }
        if token.contains(where: { "^$*|&=?~@!".contains($0) }) { return true }
        if let slash = token.firstIndex(of: "/") {
            return (try? IPAddress(String(token[..<slash]))) == nil
        }
        return false
    }
}
