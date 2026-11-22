import RiftCore
import Foundation

public enum RuntimeEventReason: String, Sendable, Hashable, Codable {
    case concreteDecision
    case unmatchedModeFallback
    case promptUnavailableFallback
    case promptDeadlineFallback
    case noActivePolicy
}

public enum RuntimeEventKind: String, Sendable, Hashable, Codable {
    case decision
    case statistics
    case closed
}

public enum RuntimeFlowEndReason: String, Sendable, Hashable, Codable {
    case networkExtensionReport
    case providerStopped
    case appRestartAbandoned
}

public struct RuntimeEvent: Sendable, Hashable, Codable {
    public let providerEpoch: UUID
    public let sequence: UInt64
    public let kind: RuntimeEventKind
    public let occurredAt: Date
    public let flow: FlowDescriptor
    public let action: FilterAction
    public let reason: RuntimeEventReason
    public let policy: PolicyTuple?
    public let winningRuleID: UUID?
    public let affectingRuleIDs: [UUID]
    public let explanation: String?
    public let bytesInbound: UInt64?
    public let bytesOutbound: UInt64?
    public let flowEndReason: RuntimeFlowEndReason?
    public let notificationRequested: Bool
    /// The process ID and path behind a decision. Nil from a filter older
    /// than protocol 1.4 and on events that only report bytes or a close.
    public let processes: FlowProcessDetails?

    public init(
        providerEpoch: UUID,
        sequence: UInt64,
        kind: RuntimeEventKind = .decision,
        occurredAt: Date,
        flow: FlowDescriptor,
        action: FilterAction,
        reason: RuntimeEventReason,
        policy: PolicyTuple?,
        winningRuleID: UUID? = nil,
        affectingRuleIDs: [UUID] = [],
        explanation: String? = nil,
        bytesInbound: UInt64? = nil,
        bytesOutbound: UInt64? = nil,
        flowEndReason: RuntimeFlowEndReason? = nil,
        notificationRequested: Bool = false,
        processes: FlowProcessDetails? = nil
    ) {
        self.providerEpoch = providerEpoch
        self.sequence = sequence
        self.kind = kind
        self.occurredAt = occurredAt
        self.flow = flow
        self.action = action
        self.reason = reason
        self.policy = policy
        self.winningRuleID = winningRuleID
        self.affectingRuleIDs = Array(affectingRuleIDs.prefix(256))
        self.explanation = explanation.map { String($0.prefix(512)) }
        self.bytesInbound = bytesInbound
        self.bytesOutbound = bytesOutbound
        self.flowEndReason = flowEndReason
        self.notificationRequested = notificationRequested
        self.processes = processes
    }

    private enum CodingKeys: String, CodingKey {
        case providerEpoch, sequence, kind, occurredAt, flow, action, reason, policy
        case winningRuleID, affectingRuleIDs, explanation, bytesInbound, bytesOutbound
        case flowEndReason
        case notificationRequested
        case processes
    }

    /// The event as a controller speaking `version` can decode it. An app
    /// older than protocol 1.4 refuses a message with fields it doesn't know.
    public func compatible(with version: ProtocolVersion) -> RuntimeEvent {
        guard !version.supports(minimum: .extendedPolicy), processes != nil else { return self }
        return replacing(bytesInbound: bytesInbound, bytesOutbound: bytesOutbound, processes: nil)
    }

    /// The same event with other byte counts, or without its process details.
    public func replacing(
        bytesInbound: UInt64?,
        bytesOutbound: UInt64?,
        processes: FlowProcessDetails?
    ) -> RuntimeEvent {
        RuntimeEvent(
            providerEpoch: providerEpoch, sequence: sequence, kind: kind, occurredAt: occurredAt,
            flow: flow, action: action, reason: reason, policy: policy,
            winningRuleID: winningRuleID, affectingRuleIDs: affectingRuleIDs,
            explanation: explanation, bytesInbound: bytesInbound, bytesOutbound: bytesOutbound,
            flowEndReason: flowEndReason, notificationRequested: notificationRequested,
            processes: processes
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        providerEpoch = try values.decode(UUID.self, forKey: .providerEpoch)
        sequence = try values.decode(UInt64.self, forKey: .sequence)
        kind = try values.decodeIfPresent(RuntimeEventKind.self, forKey: .kind) ?? .decision
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        flow = try values.decode(FlowDescriptor.self, forKey: .flow)
        action = try values.decode(FilterAction.self, forKey: .action)
        reason = try values.decode(RuntimeEventReason.self, forKey: .reason)
        policy = try values.decodeIfPresent(PolicyTuple.self, forKey: .policy)
        winningRuleID = try values.decodeIfPresent(UUID.self, forKey: .winningRuleID)
        affectingRuleIDs = try values.decodeIfPresent([UUID].self, forKey: .affectingRuleIDs) ?? []
        explanation = try values.decodeIfPresent(String.self, forKey: .explanation)
        bytesInbound = try values.decodeIfPresent(UInt64.self, forKey: .bytesInbound)
        bytesOutbound = try values.decodeIfPresent(UInt64.self, forKey: .bytesOutbound)
        flowEndReason = try values.decodeIfPresent(RuntimeFlowEndReason.self, forKey: .flowEndReason)
        notificationRequested = try values.decodeIfPresent(Bool.self, forKey: .notificationRequested) ?? false
        processes = try values.decodeIfPresent(FlowProcessDetails.self, forKey: .processes)
    }
}

public struct RuntimeEventSeed: Sendable {
    public let kind: RuntimeEventKind
    public let occurredAt: Date
    public let flow: FlowDescriptor
    public let action: FilterAction
    public let reason: RuntimeEventReason
    public let policy: PolicyTuple?
    public let winningRuleID: UUID?
    public let affectingRuleIDs: [UUID]
    public let explanation: String?
    public let bytesInbound: UInt64?
    public let bytesOutbound: UInt64?
    public let flowEndReason: RuntimeFlowEndReason?
    public let notificationRequested: Bool
    public let processes: FlowProcessDetails?

    public init(
        kind: RuntimeEventKind = .decision,
        occurredAt: Date,
        flow: FlowDescriptor,
        action: FilterAction,
        reason: RuntimeEventReason,
        policy: PolicyTuple?,
        winningRuleID: UUID? = nil,
        affectingRuleIDs: [UUID] = [],
        explanation: String? = nil,
        bytesInbound: UInt64? = nil,
        bytesOutbound: UInt64? = nil,
        flowEndReason: RuntimeFlowEndReason? = nil,
        notificationRequested: Bool = false,
        processes: FlowProcessDetails? = nil
    ) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.flow = flow
        self.action = action
        self.reason = reason
        self.policy = policy
        self.winningRuleID = winningRuleID
        self.affectingRuleIDs = Array(affectingRuleIDs.prefix(256))
        self.explanation = explanation.map { String($0.prefix(512)) }
        self.bytesInbound = bytesInbound
        self.bytesOutbound = bytesOutbound
        self.flowEndReason = flowEndReason
        self.notificationRequested = notificationRequested
        self.processes = processes
    }
}

public struct EphemeralNotificationEvent: Sendable, Hashable, Codable {
    public let id: UUID
    public let occurredAt: Date
    public let flow: FlowDescriptor
    public let action: FilterAction
    public let reason: RuntimeEventReason

    public init(
        id: UUID = UUID(),
        occurredAt: Date,
        flow: FlowDescriptor,
        action: FilterAction,
        reason: RuntimeEventReason
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.flow = flow
        self.action = action
        self.reason = reason
    }
}

public struct RuntimeEventBatch: Sendable, Hashable, Codable {
    public let providerEpoch: UUID?
    public let events: [RuntimeEvent]
    public let droppedCount: UInt64

    public init(providerEpoch: UUID?, events: [RuntimeEvent], droppedCount: UInt64) {
        self.providerEpoch = providerEpoch
        self.events = events
        self.droppedCount = droppedCount
    }
}
