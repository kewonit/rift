import AbyssCore
import AbyssIPC
import Foundation

public enum MonitorHierarchyKind: String, Sendable, Hashable {
    case application
    case helper
    case route
    case hostname
    case address
    case country
    case city
    case nonGeographic
    case flow
}

public enum MonitorRuleCoverageState: String, Sendable, Hashable {
    case exact
    case broader
    case narrower
    case mixed
    case savedPendingEnforcement
    case persistedPendingProvider
    case applyFailed
    case unresolved
    case policyChanged
    case historicalRuleMissing
    case identityChanged
    case hostnameUnavailable
    case noRule
}

public struct MonitorRuleCoverage: Sendable, Hashable {
    public let state: MonitorRuleCoverageState
    public let ruleIDs: Set<UUID>
    public let winningRuleID: UUID?

    public init(
        state: MonitorRuleCoverageState,
        ruleIDs: Set<UUID> = [],
        winningRuleID: UUID? = nil
    ) {
        self.state = state
        self.ruleIDs = ruleIDs
        self.winningRuleID = winningRuleID
    }
}

public struct MonitorAggregate: Sendable, Hashable {
    public let flowCount: Int
    public let allowed: Int
    public let denied: Int
    public let unresolved: Int
    public let bytesInbound: UInt64?
    public let bytesOutbound: UInt64?
    public let coverage: HistoryCoverage
    public let firstSeen: Date
    public let lastSeen: Date

    init(rows: [MonitorEventRow]) {
        flowCount = rows.count
        allowed = rows.filter {
            $0.event.action == .allow && $0.event.reason == .concreteDecision
        }.count
        denied = rows.filter {
            $0.event.action == .deny && $0.event.reason == .concreteDecision
        }.count
        unresolved = rows.filter { $0.event.reason != .concreteDecision }.count
        bytesInbound = Self.total(rows.map(\.bytesInbound))
        bytesOutbound = Self.total(rows.map(\.bytesOutbound))
        coverage = rows.contains { $0.coverage == .gap } ? .gap
            : rows.contains { $0.coverage == .partial } ? .partial : .complete
        firstSeen = rows.map(\.event.occurredAt).min() ?? .distantPast
        lastSeen = rows.map(\.event.occurredAt).max() ?? .distantPast
    }

    private static func total(_ values: [UInt64?]) -> UInt64? {
        guard values.contains(where: { $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(Optional<UInt64>(0)) { result, value in
            guard let result else { return nil }
            let (sum, overflow) = result.addingReportingOverflow(value)
            return overflow ? nil : sum
        }
    }
}

public struct MonitorHierarchyNode: Sendable, Hashable, Identifiable {
    public let id: String
    public let kind: MonitorHierarchyKind
    public let title: String
    public let subtitle: String?
    public let aggregate: MonitorAggregate
    public let ruleCoverage: MonitorRuleCoverage
    public let eventID: String?
    public let exactRuleSeed: MonitorExactRuleSeed?
    public let ruleSeedEventID: String?
    public let presentationIdentity: ProcessIdentity?
    public let children: [MonitorHierarchyNode]?
}

public struct MonitorExactRuleSeed: Sendable, Hashable {
    public let process: ProcessCondition
    public let destination: DestinationCondition
    public let transport: ProtocolCondition
    public let port: PortRange
    public let direction: DirectionCondition
    public let owner: OwnerCondition

    public static func make(from row: MonitorEventRow) -> MonitorExactRuleSeed? {
        let flow = row.event.flow
        guard let endpoint = flow.destinationEndpoint,
              let portValue = endpoint.port,
              let port = try? PortRange(portValue, portValue),
              let process = process(for: flow),
              let transport = transport(for: flow.transportProtocol),
              let owner = owner(for: flow.owner) else { return nil }
        let destination: DestinationCondition
        if flow.direction == .outgoing, let host = flow.observedHostname {
            guard let value = try? DestinationCondition.normalizedExactHostnameSet([host]) else {
                return nil
            }
            destination = value
        } else {
            guard let value = try? DestinationCondition.normalizedIPSet([
                IPInterval(exact: endpoint.address),
            ]) else { return nil }
            destination = value
        }
        return MonitorExactRuleSeed(
            process: process,
            destination: destination,
            transport: transport,
            port: port,
            direction: flow.direction == .outgoing ? .outgoing : .incoming,
            owner: owner
        )
    }

    private static func process(for flow: FlowDescriptor) -> ProcessCondition? {
        if let app = flow.sourceAppIdentity,
           let helper = flow.sourceProcessIdentity,
           app != helper {
            return .appViaHelper(app: app, helper: helper)
        }
        return (flow.sourceProcessIdentity ?? flow.sourceAppIdentity).map(ProcessCondition.exact)
    }

    private static func transport(for value: TransportProtocol) -> ProtocolCondition? {
        switch value {
        case .tcp: .tcp
        case .udp: .udp
        case .unsupported: nil
        }
    }

    private static func owner(for value: FlowOwner) -> OwnerCondition? {
        switch value {
        case .user: .authorizedUser
        case .system: .system
        case .unknown: nil
        }
    }
}

public enum MonitorCoverageEvaluator {
    public static func evaluate(
        _ rows: [MonitorEventRow],
        configuration: PolicyConfigurationDraft,
        enforcementState: PolicyOutboxState,
        desiredTuple: PolicyTuple? = nil,
        now: Date = Date()
    ) -> [String: MonitorRuleCoverage] {
        let matcher = CompiledRuleMatcher(rules: configuration.rules)
        let context = MatchContext(
            activeProfileID: configuration.activeProfileID,
            enabledLocalGroupIDs: configuration.enabledLocalGroupIDs,
            authorizedUID: configuration.authorizedUID,
            policyTime: PolicyTime(now: now, expiryMetadata: .available(alreadyExpired: []))
        )
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let decision = matcher.decision(
                for: row.event.flow,
                context: context,
                mode: configuration.operationMode
            )
            let value = coverage(
                row: row,
                decision: decision,
                rules: configuration.rules,
                enforcementState: enforcementState,
                desiredTuple: desiredTuple
            )
            return (row.id, value)
        })
    }

    static func aggregate(_ values: [MonitorRuleCoverage]) -> MonitorRuleCoverage {
        guard let first = values.first else { return MonitorRuleCoverage(state: .noRule) }
        let allIDs = values.reduce(into: Set<UUID>()) { $0.formUnion($1.ruleIDs) }
        if values.allSatisfy({ $0.state == first.state && $0.ruleIDs == first.ruleIDs }) {
            let winner = values.allSatisfy({ $0.winningRuleID == first.winningRuleID })
                ? first.winningRuleID : nil
            return MonitorRuleCoverage(
                state: first.state, ruleIDs: allIDs, winningRuleID: winner
            )
        }
        let uncovered: Set<MonitorRuleCoverageState> = [
            .noRule, .unresolved, .policyChanged, .historicalRuleMissing,
            .identityChanged, .hostnameUnavailable,
        ]
        let hasCovered = values.contains { !uncovered.contains($0.state) }
        let hasUncovered = values.contains { uncovered.contains($0.state) }
        return MonitorRuleCoverage(
            state: hasCovered && hasUncovered ? .narrower : .mixed,
            ruleIDs: allIDs
        )
    }

    private static func coverage(
        row: MonitorEventRow,
        decision: Decision,
        rules: [Rule],
        enforcementState: PolicyOutboxState,
        desiredTuple: PolicyTuple?
    ) -> MonitorRuleCoverage {
        let historicalRuleID = row.event.winningRuleID
        let historicalRuleExists = historicalRuleID.map { id in
            rules.contains { $0.id == id }
        } ?? true
        let policyChanged = row.event.policy.flatMap { eventTuple in
            desiredTuple.map { eventTuple != $0 }
        } ?? false
        if let winnerID = decision.filter.winningRuleID,
           let winner = rules.first(where: { $0.id == winnerID }) {
            let state: MonitorRuleCoverageState
            switch enforcementState {
            case .savedPendingEnforcement: state = .savedPendingEnforcement
            case .persistedPendingProvider: state = .persistedPendingProvider
            case .applyFailed: state = .applyFailed
            case .enforced:
                if !historicalRuleExists {
                    state = .historicalRuleMissing
                } else if policyChanged {
                    state = .policyChanged
                } else {
                    state = isExact(winner, for: row.event.flow) ? .exact : .broader
                }
            }
            var ruleIDs = Set(decision.filter.affectingRuleIDs)
            if let historicalRuleID { ruleIDs.insert(historicalRuleID) }
            return MonitorRuleCoverage(
                state: state,
                ruleIDs: ruleIDs,
                winningRuleID: winnerID
            )
        }
        if let historicalID = historicalRuleID, !historicalRuleExists {
            return MonitorRuleCoverage(
                state: .historicalRuleMissing,
                ruleIDs: [historicalID]
            )
        }
        if policyChanged {
            return MonitorRuleCoverage(
                state: .policyChanged,
                ruleIDs: Set(row.event.affectingRuleIDs)
            )
        }
        if let historicalID = historicalRuleID,
           let current = rules.first(where: { $0.id == historicalID }),
           !processMatches(current.process, flow: row.event.flow) {
            return MonitorRuleCoverage(
                state: .identityChanged,
                ruleIDs: [historicalID],
                winningRuleID: historicalID
            )
        }
        if row.event.flow.observedHostname == nil,
           row.event.flow.destinationEndpoint?.hostnameCoverage != .observed {
            return MonitorRuleCoverage(state: .hostnameUnavailable)
        }
        if row.event.reason != .concreteDecision {
            return MonitorRuleCoverage(state: .unresolved)
        }
        return MonitorRuleCoverage(state: .noRule)
    }

    private static func isExact(_ rule: Rule, for flow: FlowDescriptor) -> Bool {
        guard processMatches(rule.process, flow: flow),
              rule.transportProtocol != .anySupportedProtocol,
              rule.direction != .bidirectional,
              let endpoint = flow.destinationEndpoint,
              let endpointPort = endpoint.port,
              rule.port?.lowerBound == endpointPort,
              rule.port?.upperBound == endpointPort else { return false }
        switch rule.destination {
        case .ipSet(let values):
            return values.count == 1
                && values[0].lowerBound == endpoint.address
                && values[0].upperBound == endpoint.address
        case .exactHostnameSet(let values):
            return values.count == 1 && values[0] == flow.observedHostname
        case .domainSet, .endpointClass, .anyEndpoint:
            return false
        }
    }

    private static func processMatches(
        _ condition: ProcessCondition,
        flow: FlowDescriptor
    ) -> Bool {
        switch condition {
        case .anyProcess: false
        case .exact(let identity):
            flow.sourceAppIdentity == identity || flow.sourceProcessIdentity == identity
        case .appViaHelper(let app, let helper):
            flow.sourceAppIdentity == app && flow.sourceProcessIdentity == helper
        }
    }
}
