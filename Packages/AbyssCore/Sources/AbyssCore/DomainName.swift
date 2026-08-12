import Foundation

public enum DomainNameError: Error, Sendable, Equatable {
    case empty
    case unicodeUnsupported
    case nameTooLong
    case emptyLabel
    case labelTooLong
    case invalidCharacter
    case leadingOrTrailingHyphen
    case malformedALabel
}

public struct DomainName: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let ascii: String

    public init(_ input: String) throws {
        guard !input.isEmpty else { throw DomainNameError.empty }
        guard input.unicodeScalars.allSatisfy(\.isASCII) else {
            throw DomainNameError.unicodeUnsupported
        }

        let withoutRootDot: Substring
        if input.hasSuffix(".") {
            withoutRootDot = input.dropLast()
        } else {
            withoutRootDot = input[...]
        }
        guard !withoutRootDot.isEmpty else { throw DomainNameError.empty }

        let canonical = withoutRootDot.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard canonical.utf8.count <= 253 else { throw DomainNameError.nameTooLong }
        let labels = canonical.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty else { throw DomainNameError.emptyLabel }
            guard label.utf8.count <= 63 else { throw DomainNameError.labelTooLong }
            if label.hasPrefix("xn--") {
                throw DomainNameError.malformedALabel
            }
            guard label.first != "-", label.last != "-" else {
                throw DomainNameError.leadingOrTrailingHyphen
            }
            guard label.utf8.allSatisfy({ byte in
                (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 45
            }) else {
                throw DomainNameError.invalidCharacter
            }
        }
        self.ascii = canonical
    }

    public var description: String { ascii }
    public var labelCount: Int { ascii.split(separator: ".").count }

    public func isEqualToOrSubdomain(of domain: DomainName) -> Bool {
        ascii == domain.ascii || ascii.hasSuffix("." + domain.ascii)
    }

    public static func < (lhs: DomainName, rhs: DomainName) -> Bool {
        lhs.ascii < rhs.ascii
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ASCII/Punycode domain: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ascii)
    }
}
