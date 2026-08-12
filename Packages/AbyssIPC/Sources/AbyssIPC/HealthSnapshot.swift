import Foundation

public struct HealthSnapshot: Sendable, Equatable, Codable {
    public enum ProviderStatus: String, Sendable, Codable {
        case unavailable
        case starting
        case ready
        case degraded
    }

    public let protocolVersion: ProtocolVersion
    public let providerStatus: ProviderStatus
    public let filterEnabled: Bool
    public let redactedMessage: String?

    public init(
        protocolVersion: ProtocolVersion = .current,
        providerStatus: ProviderStatus,
        filterEnabled: Bool,
        redactedMessage: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.providerStatus = providerStatus
        self.filterEnabled = filterEnabled
        self.redactedMessage = redactedMessage
    }
}
