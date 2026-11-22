import Foundation

public struct MatchContext: Sendable, Equatable {
    public let activeProfileID: UUID?
    public let enabledLocalGroupIDs: Set<UUID>
    public let authorizedUID: UInt32
    public let policyTime: PolicyTime

    public init(
        activeProfileID: UUID?,
        enabledLocalGroupIDs: Set<UUID>,
        authorizedUID: UInt32,
        policyTime: PolicyTime
    ) {
        self.activeProfileID = activeProfileID
        self.enabledLocalGroupIDs = enabledLocalGroupIDs
        self.authorizedUID = authorizedUID
        self.policyTime = policyTime
    }
}

enum RuleRejection: Error, Sendable, Equatable {
    case disabled
    case inactiveGroup
    case inactiveProfile
    case expired
    case expiryMetadataUnavailable
    case unsupportedProtocol
    case protocolMismatch
    case identityUnavailable
    case processMismatch
    case endpointUnavailable
    case hostnameUnavailable
    case destinationMismatch
    case portUnavailable
    case portMismatch
    case ownerUnavailable
    case ownerMismatch
    case directionMismatch
}

struct ApplicableRule: Sendable {
    let rule: Rule
    let destination: DestinationSpecificity
}

enum RuleApplicability {
    static func evaluate(
        rule: Rule,
        flow: FlowDescriptor,
        context: MatchContext
    ) -> Result<ApplicableRule, RuleRejection> {
        guard rule.isEnabled else { return .failure(.disabled) }
        if let groupID = rule.localGroupID,
           !context.enabledLocalGroupIDs.contains(groupID) {
            return .failure(.inactiveGroup)
        }
        if let profileID = rule.profileID,
           profileID != context.activeProfileID {
            return .failure(.inactiveProfile)
        }
        switch context.policyTime.eligibility(of: rule) {
        case .eligible: break
        case .expired: return .failure(.expired)
        case .expiryMetadataUnavailable: return .failure(.expiryMetadataUnavailable)
        }
        guard protocolMatches(rule.transportProtocol, flow.transportProtocol) else {
            if case .unsupported = flow.transportProtocol {
                return .failure(.unsupportedProtocol)
            }
            return .failure(.protocolMismatch)
        }
        guard processMatches(rule.process, flow: flow) else {
            if flow.sourceAppIdentity == nil, flow.sourceProcessIdentity == nil,
               rule.process != .anyProcess {
                return .failure(.identityUnavailable)
            }
            return .failure(.processMismatch)
        }
        guard let endpoint = flow.destinationEndpoint else {
            return .failure(.endpointUnavailable)
        }
        guard let destination = destinationMatch(rule, flow: flow, endpoint: endpoint) else {
            switch rule.destination {
            case .exactHostnameSet where flow.observedHostname == nil,
                 .domainSet where flow.observedHostname == nil:
                return .failure(.hostnameUnavailable)
            default:
                return .failure(.destinationMismatch)
            }
        }
        if let requiredPort = rule.port {
            guard let flowPort = endpoint.port else { return .failure(.portUnavailable) }
            guard requiredPort.contains(flowPort) else { return .failure(.portMismatch) }
        }
        // A blocklist names destinations to block on the whole Mac, so it
        // covers every owner: root, other accounts, and unknown owners too.
        // Its stored owner stays `.authorizedUser`, so formats don't change.
        guard rule.priority == .blocklistDeny
            || ownerMatches(rule.owner, flow.owner, authorizedUID: context.authorizedUID) else {
            if flow.owner == .unknown { return .failure(.ownerUnavailable) }
            return .failure(.ownerMismatch)
        }
        guard directionMatches(rule.direction, flow.direction) else {
            return .failure(.directionMismatch)
        }
        return .success(ApplicableRule(rule: rule, destination: destination))
    }

    private static func protocolMatches(
        _ condition: ProtocolCondition,
        _ transport: TransportProtocol
    ) -> Bool {
        switch (condition, transport) {
        case (.tcp, .tcp), (.udp, .udp): true
        case (.anySupportedProtocol, .tcp), (.anySupportedProtocol, .udp): true
        default: false
        }
    }

    private static func processMatches(_ condition: ProcessCondition, flow: FlowDescriptor) -> Bool {
        switch condition {
        case .anyProcess:
            true
        case .exact(let identity):
            flow.sourceProcessIdentity == identity || flow.sourceAppIdentity == identity
        case .appViaHelper(let app, let helper):
            flow.sourceAppIdentity == app && flow.sourceProcessIdentity == helper
        }
    }

    /// `endpoint` is the flow's destination: the remote side of an outgoing
    /// flow, and this Mac's side of an incoming one, so incoming rules name a
    /// local service. Two conditions describe the peer instead: a blocklist,
    /// and "local network" on an incoming flow.
    private static func destinationMatch(
        _ rule: Rule,
        flow: FlowDescriptor,
        endpoint: Endpoint
    ) -> DestinationSpecificity? {
        switch rule.destination {
        case .ipSet(let values):
            let address = rule.priority == .blocklistDeny
                ? flow.remoteEndpoint?.address : endpoint.address
            guard let address else { return nil }
            let matches = values.filter { $0.contains(address) }
            guard let best = matches.min(by: { lhs, rhs in
                if lhs.spanMagnitude != rhs.spanMagnitude {
                    return lhs.spanMagnitude.lexicographicallyPrecedes(rhs.spanMagnitude)
                }
                return lhs < rhs
            }) else { return nil }
            return .ip(set: values, matched: best)
        case .exactHostnameSet(let values):
            guard flow.direction == .outgoing, let host = flow.observedHostname,
                  values.contains(host) else { return nil }
            return .hostname(set: values, matched: host)
        case .domainSet(let values):
            guard flow.direction == .outgoing, let host = flow.observedHostname else { return nil }
            let matches = values.filter { host.isEqualToOrSubdomain(of: $0) }
            // The most specific member that matches stands for the set.
            guard let best = matches.min(by: { lhs, rhs in
                if lhs.labelCount != rhs.labelCount { return lhs.labelCount > rhs.labelCount }
                return lhs < rhs
            }) else { return nil }
            return .domain(set: values, matched: best)
        case .endpointClass(let value):
            let classes = value == .localNetwork && flow.direction == .incoming
                ? flow.remoteEndpoint?.classes ?? [] : endpoint.classes
            guard classes.contains(value) else { return nil }
            return .endpointClass(value)
        case .anyEndpoint:
            return .anyEndpoint
        }
    }

    private static func ownerMatches(
        _ condition: OwnerCondition,
        _ owner: FlowOwner,
        authorizedUID: UInt32
    ) -> Bool {
        switch (condition, owner) {
        case (.authorizedUser, .user(let uid)):
            uid == authorizedUID
        case (.specificUser(let expected), .user(let actual)):
            expected == authorizedUID && actual == expected
        case (.system, .system):
            true
        default:
            false
        }
    }

    private static func directionMatches(
        _ condition: DirectionCondition,
        _ direction: TrafficDirection
    ) -> Bool {
        switch (condition, direction) {
        case (.bidirectional, _), (.incoming, .incoming), (.outgoing, .outgoing): true
        default: false
        }
    }
}
