import RiftCore
import RiftIPC
import Foundation

public enum AlertRuleBuilderError: Error, Sendable, Equatable {
    case identityUnavailable
    case endpointUnavailable
    case unsupportedProtocol
    case foreignOwner
    case systemOwnerConfirmationRequired
}

public enum AlertDestinationScope: Sendable, Equatable {
    case exactObservedEndpoint
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
        case .exactObservedEndpoint:
            if let hostname = endpoint.hostname {
                destination = try .normalizedExactHostnameSet([hostname])
            } else {
                destination = try .normalizedIPSet([IPInterval(exact: endpoint.address)])
            }
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
