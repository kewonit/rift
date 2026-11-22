import RiftCore
import Foundation

public struct PromptRequest: Sendable, Hashable, Codable {
    public static let maximumCohortCount: UInt16 = 256

    public let nonce: UUID
    public let providerEpoch: UUID
    public let lineageID: UUID
    public let generation: UInt64
    public let flowID: UUID
    public let observedAt: Date
    public let deadline: Date
    public let cohortCount: UInt16
    public let owner: FlowOwner
    public let appIdentity: ProcessIdentity?
    public let processIdentity: ProcessIdentity?
    public let direction: TrafficDirection
    public let transportProtocol: TransportProtocol
    public let endpoint: Endpoint?
    public let winningRuleID: UUID?
    public let affectingRuleIDs: [UUID]
    /// What the filter does at the deadline. Nil from a filter older than
    /// protocol 1.4, which always allows.
    public let unansweredAction: FilterAction?
    /// The process ID and path of what's connecting. Nil from a filter older
    /// than protocol 1.4, and for a connection whose details are hidden.
    public let processes: FlowProcessDetails?

    public init(
        nonce: UUID,
        providerEpoch: UUID,
        lineageID: UUID,
        generation: UInt64,
        flowID: UUID,
        observedAt: Date,
        deadline: Date? = nil,
        cohortCount: UInt16 = 1,
        owner: FlowOwner,
        appIdentity: ProcessIdentity?,
        processIdentity: ProcessIdentity?,
        direction: TrafficDirection,
        transportProtocol: TransportProtocol,
        endpoint: Endpoint?,
        winningRuleID: UUID?,
        affectingRuleIDs: [UUID],
        unansweredAction: FilterAction? = nil,
        processes: FlowProcessDetails? = nil
    ) {
        self.nonce = nonce
        self.providerEpoch = providerEpoch
        self.lineageID = lineageID
        self.generation = generation
        self.flowID = flowID
        self.observedAt = observedAt
        self.deadline = deadline ?? observedAt.addingTimeInterval(
            transportProtocol == .udp ? 8 : 30
        )
        self.cohortCount = min(max(cohortCount, 1), Self.maximumCohortCount)
        self.owner = owner
        self.appIdentity = appIdentity
        self.processIdentity = processIdentity
        self.direction = direction
        self.transportProtocol = transportProtocol
        self.endpoint = endpoint
        self.winningRuleID = winningRuleID
        self.affectingRuleIDs = affectingRuleIDs
        self.unansweredAction = unansweredAction
        self.processes = processes
    }

    private enum CodingKeys: String, CodingKey {
        case nonce, providerEpoch, lineageID, generation, flowID, observedAt, deadline, cohortCount
        case owner, appIdentity, processIdentity, direction, transportProtocol, endpoint
        case winningRuleID, affectingRuleIDs, unansweredAction, processes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nonce = try values.decode(UUID.self, forKey: .nonce)
        providerEpoch = try values.decode(UUID.self, forKey: .providerEpoch)
        lineageID = try values.decode(UUID.self, forKey: .lineageID)
        generation = try values.decode(UInt64.self, forKey: .generation)
        flowID = try values.decode(UUID.self, forKey: .flowID)
        observedAt = try values.decode(Date.self, forKey: .observedAt)
        owner = try values.decode(FlowOwner.self, forKey: .owner)
        appIdentity = try values.decodeIfPresent(ProcessIdentity.self, forKey: .appIdentity)
        processIdentity = try values.decodeIfPresent(ProcessIdentity.self, forKey: .processIdentity)
        direction = try values.decode(TrafficDirection.self, forKey: .direction)
        transportProtocol = try values.decode(TransportProtocol.self, forKey: .transportProtocol)
        deadline = try values.decodeIfPresent(Date.self, forKey: .deadline)
            ?? observedAt.addingTimeInterval(transportProtocol == .udp ? 8 : 30)
        let decodedCount = try values.decodeIfPresent(UInt16.self, forKey: .cohortCount) ?? 1
        guard (1...Self.maximumCohortCount).contains(decodedCount) else {
            throw DecodingError.dataCorruptedError(
                forKey: .cohortCount,
                in: values,
                debugDescription: "Prompt cohort count is outside the supported bound."
            )
        }
        cohortCount = decodedCount
        endpoint = try values.decodeIfPresent(Endpoint.self, forKey: .endpoint)
        winningRuleID = try values.decodeIfPresent(UUID.self, forKey: .winningRuleID)
        affectingRuleIDs = try values.decode([UUID].self, forKey: .affectingRuleIDs)
        unansweredAction = try values.decodeIfPresent(FilterAction.self, forKey: .unansweredAction)
        processes = try values.decodeIfPresent(FlowProcessDetails.self, forKey: .processes)
    }

    /// The same prompt with a new deadline and count, for a connection that
    /// joined the ones already waiting.
    public func updated(deadline: Date, cohortCount: UInt16) -> PromptRequest {
        copy(deadline: deadline, cohortCount: cohortCount, extended: true)
    }

    /// The prompt as a controller speaking `version` can decode it. An app
    /// older than protocol 1.4 refuses a message with fields it doesn't know,
    /// so those are left out for it.
    public func compatible(with version: ProtocolVersion) -> PromptRequest {
        guard !version.supports(minimum: .extendedPolicy),
              unansweredAction != nil || processes != nil else { return self }
        return copy(deadline: deadline, cohortCount: cohortCount, extended: false)
    }

    private func copy(deadline: Date, cohortCount: UInt16, extended: Bool) -> PromptRequest {
        PromptRequest(
            nonce: nonce,
            providerEpoch: providerEpoch,
            lineageID: lineageID,
            generation: generation,
            flowID: flowID,
            observedAt: observedAt,
            deadline: deadline,
            cohortCount: cohortCount,
            owner: owner,
            appIdentity: appIdentity,
            processIdentity: processIdentity,
            direction: direction,
            transportProtocol: transportProtocol,
            endpoint: endpoint,
            winningRuleID: winningRuleID,
            affectingRuleIDs: affectingRuleIDs,
            unansweredAction: extended ? unansweredAction : nil,
            processes: extended ? processes : nil
        )
    }
}

public struct PromptAnswer: Sendable, Hashable, Codable {
    public let nonce: UUID
    public let providerEpoch: UUID
    public let lineageID: UUID
    public let generation: UInt64
    public let action: FilterAction

    public init(
        nonce: UUID,
        providerEpoch: UUID,
        lineageID: UUID,
        generation: UInt64,
        action: FilterAction
    ) {
        self.nonce = nonce
        self.providerEpoch = providerEpoch
        self.lineageID = lineageID
        self.generation = generation
        self.action = action
    }
}
