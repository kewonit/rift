import RiftCore
import RiftIPC
import Foundation

public enum AlertRuleBuilderError: Error, Sendable, Equatable {
    case identityUnavailable
    case endpointUnavailable
    case unsupportedProtocol
    case foreignOwner
    case systemOwnerConfirmationRequired
    /// The connection has no name, or the name is itself a registry suffix.
    case domainUnavailable
}

public enum AlertDestinationScope: Sendable, Equatable {
    /// The observed host or address, on the observed port.
    case exactObservedEndpoint
    /// The observed host or address, on any port.
    case observedDestinationAnyPort
    /// The domain the observed name was registered under, and every name
    /// below it, on any port.
    case observedDomain
    case anyEndpoint
}

public enum AlertRuleBuilder {
    public static func build(
        prompt: PromptRequest,
        action: FilterAction,
        lineageID: UUID,
        authorizedUID: UInt32,
        expiresAt: Date?,
        profileID: UUID? = nil,
        destinationScope: AlertDestinationScope = .exactObservedEndpoint,
        allowSystemOwner: Bool = false,
        notes: String = "",
        suffixes: PublicSuffixList = .shared,
        now: Date
    ) throws -> Rule {
        let process: ProcessCondition
        if let app = prompt.appIdentity, let helper = prompt.processIdentity, app != helper {
            process = .appViaHelper(app: app, helper: helper)
        } else if let identity = prompt.appIdentity ?? prompt.processIdentity {
            process = .exact(identity)
        } else {
            throw AlertRuleBuilderError.identityUnavailable
        }
        guard let endpoint = prompt.endpoint else {
            throw AlertRuleBuilderError.endpointUnavailable
        }
        let destination: DestinationCondition
        switch destinationScope {
        case .exactObservedEndpoint, .observedDestinationAnyPort:
            if let hostname = endpoint.hostname {
                destination = try .normalizedExactHostnameSet([hostname])
            } else {
                destination = try .normalizedIPSet([IPInterval(exact: endpoint.address)])
            }
        case .observedDomain:
            guard prompt.direction == .outgoing, let hostname = endpoint.hostname,
                  let domain = suffixes.registrableDomain(of: hostname) else {
                throw AlertRuleBuilderError.domainUnavailable
            }
            destination = try .normalizedDomainSet([domain])
        case .anyEndpoint:
            destination = .anyEndpoint
        }
        let transport: ProtocolCondition
        switch prompt.transportProtocol {
        case .tcp: transport = .tcp
        case .udp: transport = .udp
        case .unsupported: throw AlertRuleBuilderError.unsupportedProtocol
        }
        let direction: DirectionCondition = prompt.direction == .outgoing ? .outgoing : .incoming
        let owner: OwnerCondition
        switch prompt.owner {
        case .user(let uid) where uid == authorizedUID: owner = .authorizedUser
        case .system where allowSystemOwner: owner = .system
        case .system: throw AlertRuleBuilderError.systemOwnerConfirmationRequired
        default: throw AlertRuleBuilderError.foreignOwner
        }
        let port = destinationScope == .exactObservedEndpoint
            ? try endpoint.port.map { try PortRange($0, $0) } : nil
        return try Rule(
            id: UUID(),
            lineageID: lineageID,
            revision: 1,
            action: .filter(action),
            priority: .normal,
            process: process,
            destination: destination,
            transportProtocol: transport,
            port: port,
            direction: direction,
            owner: owner,
            profileID: profileID,
            expiresAt: expiresAt,
            notes: notes,
            createdAt: now,
            modifiedAt: now
        )
    }
}
