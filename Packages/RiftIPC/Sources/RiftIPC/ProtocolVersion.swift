import Foundation

public struct ProtocolVersion: Sendable, Hashable, Codable {
    public static let baseline = ProtocolVersion(major: 1, minor: 0)
    public static let configurationReset = ProtocolVersion(major: 1, minor: 1)
    public static let activitySubscriptions = ProtocolVersion(major: 1, minor: 2)
    /// Policies may hold internationalized (`xn--`) names, which older
    /// extensions refuse to decode.
    public static let internationalNames = ProtocolVersion(major: 1, minor: 3)
    public static let current = internationalNames

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
