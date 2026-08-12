import Foundation

public struct ProtocolVersion: Sendable, Hashable, Codable {
    public static let baseline = ProtocolVersion(major: 1, minor: 0)
    public static let configurationReset = ProtocolVersion(major: 1, minor: 1)
    public static let current = configurationReset

    public let major: UInt16
    public let minor: UInt16

    public init(major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public func isCompatible(with other: ProtocolVersion) -> Bool {
        major == other.major
    }

    public func supports(minimum: ProtocolVersion) -> Bool {
        major == minimum.major && minor >= minimum.minor
    }
}
