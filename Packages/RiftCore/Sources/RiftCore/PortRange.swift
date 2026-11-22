import Foundation

public enum PortRangeError: Error, Sendable, Equatable {
    case zeroPort
    case reversedRange
    case emptyList
    case tooManyRanges(Int)
    case unreadable
    case nonCanonical
}

/// The ports a rule covers: one port, one range, or a list such as
/// `20-30, 80, 443`.
///
/// The first range keeps the two fields every earlier build wrote, so a rule
/// for one port or range encodes exactly as it always did. A list adds
/// `additional`, which only filters that speak protocol 1.4 understand.
/// Keeping the list inside this one value means code that copies a rule's
/// port can't drop part of it.
public struct PortRange: Sendable, Hashable, Comparable, Codable {
    /// The most ranges one list may hold.
    public static let maximumRanges = 16

    /// One further range of a list.
    public struct Span: Sendable, Hashable, Codable {
        public let lowerBound: UInt16
        public let upperBound: UInt16
    }

    /// The bounds of the first, lowest range.
    public let lowerBound: UInt16
    public let upperBound: UInt16
    /// The other ranges of a list, each above the one before it with a gap
    /// between. Empty for a single port or range.
    public let additional: [Span]

    public init(_ lowerBound: UInt16, _ upperBound: UInt16) throws {
        guard lowerBound != 0 else { throw PortRangeError.zeroPort }
        guard lowerBound <= upperBound else { throw PortRangeError.reversedRange }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.additional = []
    }

    /// A list in its one stored form: sorted, with ranges that overlap or
    /// touch joined, so two ways of writing the same ports are equal.
    public init(list: [ClosedRange<UInt16>]) throws {
        guard !list.isEmpty else { throw PortRangeError.emptyList }
        guard list.allSatisfy({ $0.lowerBound != 0 }) else { throw PortRangeError.zeroPort }
        var merged: [ClosedRange<UInt16>] = []
        for range in list.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last,
               last.upperBound == .max || range.lowerBound <= last.upperBound + 1 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        guard merged.count <= Self.maximumRanges else {
            throw PortRangeError.tooManyRanges(merged.count)
        }
        lowerBound = merged[0].lowerBound
        upperBound = merged[0].upperBound
        additional = merged.dropFirst().map { Span(lowerBound: $0.lowerBound, upperBound: $0.upperBound) }
    }

    /// Every range, lowest first.
    public var ranges: [ClosedRange<UInt16>] {
        [lowerBound...upperBound] + additional.map { $0.lowerBound...$0.upperBound }
    }

    public var isList: Bool { !additional.isEmpty }

    /// The port, when this is exactly one.
    public var singlePort: UInt16? {
        !isList && lowerBound == upperBound ? lowerBound : nil
    }

    public func contains(_ port: UInt16) -> Bool {
        if (lowerBound...upperBound).contains(port) { return true }
        return additional.contains { ($0.lowerBound...$0.upperBound).contains(port) }
    }

    /// Whether every port of `other` is one of these.
    public func covers(_ other: PortRange) -> Bool {
        other.ranges.allSatisfy { inner in
            ranges.contains { $0.lowerBound <= inner.lowerBound && inner.upperBound <= $0.upperBound }
        }
    }

    public func overlaps(_ other: PortRange) -> Bool {
        ranges.contains { mine in other.ranges.contains { mine.overlaps($0) } }
    }

    /// One less than the number of ports covered, so a single port is 0. A
    /// rule that covers fewer ports is the more specific one.
    public var span: UInt16 {
        UInt16(clamping: ranges.reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 } - 1)
    }

    public static func < (lhs: PortRange, rhs: PortRange) -> Bool {
        if lhs.span != rhs.span { return lhs.span < rhs.span }
        if lhs.lowerBound != rhs.lowerBound { return lhs.lowerBound < rhs.lowerBound }
        return lhs.ranges.lexicographicallyPrecedes(rhs.ranges) {
            ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound)
        }
    }

    /// `443`, `8000-8100` or `20-30, 80, 443`.
    public func text(rangeSeparator: String = "-") -> String {
        ranges.map {
            $0.lowerBound == $0.upperBound
                ? String($0.lowerBound) : "\($0.lowerBound)\(rangeSeparator)\($0.upperBound)"
        }.joined(separator: ", ")
    }

    /// Reads what a person types: ports and ranges separated by commas, with
    /// a hyphen or an en dash inside a range.
    public static func parse(_ text: String) throws -> PortRange {
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.contains(where: \.isEmpty) else { throw PortRangeError.unreadable }
        let list = try parts.map { part -> ClosedRange<UInt16> in
            let bounds = part.replacingOccurrences(of: "–", with: "-")
                .split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count),
                  bounds.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let lower = UInt16(bounds[0]), let upper = UInt16(bounds[bounds.count - 1]) else {
                throw PortRangeError.unreadable
            }
            guard lower != 0 else { throw PortRangeError.zeroPort }
            guard lower <= upper else { throw PortRangeError.reversedRange }
            return lower...upper
        }
        return try PortRange(list: list)
    }

    /// Throws unless this is the one stored form of its ports.
    public func validated() throws -> PortRange {
        guard try PortRange(list: ranges) == self else { throw PortRangeError.nonCanonical }
        return self
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let lowerBound = try container.decode(UInt16.self, forKey: .lowerBound)
        let upperBound = try container.decode(UInt16.self, forKey: .upperBound)
        let additional = try container.decodeIfPresent([Span].self, forKey: .additional) ?? []
        do {
            let first = try PortRange(lowerBound, upperBound)
            guard !additional.isEmpty else {
                // An empty list isn't how a single range is written.
                guard !container.contains(.additional) else { throw PortRangeError.nonCanonical }
                self = first
                return
            }
            let spans = [Span(lowerBound: lowerBound, upperBound: upperBound)] + additional
            guard spans.allSatisfy({ $0.lowerBound <= $0.upperBound }) else {
                throw PortRangeError.reversedRange
            }
            let list = try PortRange(list: spans.map { $0.lowerBound...$0.upperBound })
            guard list.lowerBound == lowerBound, list.upperBound == upperBound,
                  list.additional == additional else { throw PortRangeError.nonCanonical }
            self = list
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
        if !additional.isEmpty { try container.encode(additional, forKey: .additional) }
    }

    private enum CodingKeys: String, CodingKey {
        case lowerBound
        case upperBound
        case additional
    }
}
