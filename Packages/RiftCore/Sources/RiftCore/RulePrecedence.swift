enum DestinationSpecificity: Sendable, Equatable {
    case ip(set: [IPInterval], matched: IPInterval)
    case hostname(set: [DomainName], matched: DomainName)
    case domain(set: [DomainName], matched: DomainName)
    case endpointClass(EndpointClass)
    case anyEndpoint

    var description: String {
        switch self {
        case .ip(let set, let matched): "IP set (\(set.count)); matched \(matched)"
        case .hostname(let set, let matched): "exact hostname set (\(set.count)); matched \(matched)"
        case .domain(let set, let matched): "domain set (\(set.count)); matched \(matched)"
        case .endpointClass(let value): "endpoint class \(value.rawValue)"
        case .anyEndpoint: "any endpoint"
        }
    }

    private var kindRank: Int {
        switch self {
        case .ip: 0
        case .hostname: 1
        case .domain: 2
        case .endpointClass(.broadcast): 3
        case .endpointClass(.multicast): 4
        case .endpointClass(.bonjour): 5
        case .endpointClass(.localNetwork): 6
        case .endpointClass: 7
        case .anyEndpoint: 8
        }
    }

    private var memberCount: Int {
        switch self {
        case .ip(let set, _): set.count
        case .hostname(let set, _), .domain(let set, _): set.count
        case .endpointClass, .anyEndpoint: 1
        }
    }

    private var stableMember: String {
        switch self {
        case .ip(let set, let matched):
            matched.description + "|" + set.map(\.description).joined(separator: ",")
        case .hostname(let set, let matched), .domain(let set, let matched):
            matched.ascii + "|" + set.map(\.ascii).joined(separator: ",")
        case .endpointClass(let value): value.rawValue
        case .anyEndpoint: ""
        }
    }

    static func precedes(_ lhs: DestinationSpecificity, _ rhs: DestinationSpecificity) -> Bool {
        if lhs.kindRank != rhs.kindRank { return lhs.kindRank < rhs.kindRank }
        if lhs.memberCount != rhs.memberCount { return lhs.memberCount < rhs.memberCount }
        switch (lhs, rhs) {
        case (.ip(_, let left), .ip(_, let right)) where left.spanMagnitude != right.spanMagnitude:
            return left.spanMagnitude.lexicographicallyPrecedes(right.spanMagnitude)
        case (.domain(_, let left), .domain(_, let right)) where left.labelCount != right.labelCount:
            return left.labelCount < right.labelCount
        default:
            return lhs.stableMember < rhs.stableMember
        }
    }
}

enum RulePrecedence {
    static func precedes(_ lhs: ApplicableRule, _ rhs: ApplicableRule, includeRuleID: Bool = true) -> Bool {
        let left = lhs.rule
        let right = rhs.rule
        if priorityRank(left.priority) != priorityRank(right.priority) {
            return priorityRank(left.priority) < priorityRank(right.priority)
        }
        if lhs.destination != rhs.destination {
            return DestinationSpecificity.precedes(lhs.destination, rhs.destination)
        }
        if portKey(left.port) != portKey(right.port) { return portKey(left.port) < portKey(right.port) }
        if protocolRank(left.transportProtocol) != protocolRank(right.transportProtocol) {
            return protocolRank(left.transportProtocol) < protocolRank(right.transportProtocol)
        }
        if processRank(left.process) != processRank(right.process) {
            return processRank(left.process) < processRank(right.process)
        }
        if ownerRank(left.owner) != ownerRank(right.owner) {
            return ownerRank(left.owner) < ownerRank(right.owner)
        }
        if directionRank(left.direction) != directionRank(right.direction) {
            return directionRank(left.direction) < directionRank(right.direction)
        }
        if filterActionRank(left.action) != filterActionRank(right.action) {
            return filterActionRank(left.action) < filterActionRank(right.action)
        }
        guard includeRuleID else { return false }
        return left.id.uuidString < right.id.uuidString
    }

    static func tiedBeforeRuleID(_ lhs: ApplicableRule, _ rhs: ApplicableRule) -> Bool {
        !precedes(lhs, rhs, includeRuleID: false) && !precedes(rhs, lhs, includeRuleID: false)
    }

    static func explanation(for match: ApplicableRule, ambiguous: Bool) -> PrecedenceExplanation {
        let rule = match.rule
        return PrecedenceExplanation(
            priority: rule.priority,
            destination: match.destination.description,
            port: rule.port.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "any port",
            transportProtocol: String(describing: rule.transportProtocol),
            process: String(describing: rule.process),
            owner: String(describing: rule.owner),
            direction: rule.direction.rawValue,
            action: String(describing: rule.action),
            ambiguityResolvedByRuleID: ambiguous
        )
    }

    private static func priorityRank(_ value: RulePriority) -> Int {
        switch value {
        case .elevatedUser: 0
        case .blocklistDeny: 1
        case .normal: 2
        }
    }

    private static func portKey(_ value: PortRange?) -> (UInt32, UInt16) {
        guard let value else { return (UInt32(UInt16.max), 0) }
        return (UInt32(value.span), value.lowerBound)
    }

    private static func protocolRank(_ value: ProtocolCondition) -> Int {
        value == .anySupportedProtocol ? 1 : 0
    }

    private static func processRank(_ value: ProcessCondition) -> Int {
        switch value {
        case .appViaHelper: 0
        case .exact: 1
        case .anyProcess: 2
        }
    }

    private static func ownerRank(_ value: OwnerCondition) -> Int {
        value == .authorizedUser ? 1 : 0
    }

    private static func directionRank(_ value: DirectionCondition) -> Int {
        value == .bidirectional ? 1 : 0
    }

    private static func filterActionRank(_ value: RuleAction) -> Int {
        switch value {
        case .filter(.deny): 0
        case .filter(.allow): 1
        case .filter(.ask): 2
        case .notification, .privacy: 0
        }
    }
}
