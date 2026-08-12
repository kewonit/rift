import Foundation

public enum CodeIdentityError: Error, Sendable, Equatable {
    case emptyIdentifier
    case invalidDigest
    case wrongDigestLength(expected: Int, actual: Int)
    case pathIsNotAbsolute
}

public struct CodeDigest: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init(hex: String, expectedByteCount: Int) throws {
        guard hex.count == expectedByteCount * 2 else {
            throw CodeIdentityError.wrongDigestLength(
                expected: expectedByteCount,
                actual: hex.count / 2
            )
        }
        var parsed: [UInt8] = []
        parsed.reserveCapacity(expectedByteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw CodeIdentityError.invalidDigest
            }
            parsed.append(byte)
            index = next
        }
        bytes = parsed
    }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func < (lhs: CodeDigest, rhs: CodeDigest) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard text.count.isMultiple(of: 2), !text.isEmpty else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Digest must contain complete hexadecimal bytes"
            )
        }
        do {
            try self.init(hex: text, expectedByteCount: text.count / 2)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid digest: \(error)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct SignedCodeIdentity: Sendable, Hashable, Codable {
    public let teamIdentifier: String?
    public let signingIdentifier: String

    public init(teamIdentifier: String?, signingIdentifier: String) throws {
        guard !signingIdentifier.isEmpty else { throw CodeIdentityError.emptyIdentifier }
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }
}

public enum ProcessIdentity: Sendable, Hashable, Codable {
    case applePlatform(SignedCodeIdentity)
    case developerID(SignedCodeIdentity)
    case appStore(SignedCodeIdentity)
    case otherSigner(publicKeyHash: CodeDigest, signingIdentifier: String)
    case adHoc(cdHash: CodeDigest)
    case unsigned(normalizedPath: String, fileHash: CodeDigest)

    public static func unsigned(path: String, fileHash: CodeDigest) throws -> ProcessIdentity {
        guard path.hasPrefix("/") else { throw CodeIdentityError.pathIsNotAbsolute }
        return .unsigned(
            normalizedPath: URL(fileURLWithPath: path).standardizedFileURL.path,
            fileHash: fileHash
        )
    }

    public func validated() throws -> ProcessIdentity {
        switch self {
        case .applePlatform(let value), .developerID(let value), .appStore(let value):
            guard !value.signingIdentifier.isEmpty else { throw CodeIdentityError.emptyIdentifier }
        case .otherSigner(let hash, let identifier):
            guard hash.bytes.count == 32 else {
                throw CodeIdentityError.wrongDigestLength(expected: 32, actual: hash.bytes.count)
            }
            guard !identifier.isEmpty else { throw CodeIdentityError.emptyIdentifier }
        case .adHoc(let hash):
            guard hash.bytes.count == 20 else {
                throw CodeIdentityError.wrongDigestLength(expected: 20, actual: hash.bytes.count)
            }
        case .unsigned(let path, let hash):
            guard path.hasPrefix("/") else { throw CodeIdentityError.pathIsNotAbsolute }
            guard hash.bytes.count == 32 else {
                throw CodeIdentityError.wrongDigestLength(expected: 32, actual: hash.bytes.count)
            }
            guard URL(fileURLWithPath: path).standardizedFileURL.path == path else {
                throw CodeIdentityError.pathIsNotAbsolute
            }
        }
        return self
    }
}

extension ProcessIdentity: Comparable {
    private var stableKey: String {
        switch self {
        case .applePlatform(let value):
            "0|\(value.teamIdentifier ?? "")|\(value.signingIdentifier)"
        case .developerID(let value):
            "1|\(value.teamIdentifier ?? "")|\(value.signingIdentifier)"
        case .appStore(let value):
            "2|\(value.teamIdentifier ?? "")|\(value.signingIdentifier)"
        case .otherSigner(let hash, let identifier):
            "3|\(hash)|\(identifier)"
        case .adHoc(let hash):
            "4|\(hash)"
        case .unsigned(let path, let hash):
            "5|\(path)|\(hash)"
        }
    }

    public static func < (lhs: ProcessIdentity, rhs: ProcessIdentity) -> Bool {
        lhs.stableKey < rhs.stableKey
    }
}
