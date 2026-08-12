import AbyssCore
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
        affectingRuleIDs: [UUID]
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
    }

    private enum CodingKeys: String, CodingKey {
        case nonce, providerEpoch, lineageID, generation, flowID, observedAt, deadline, cohortCount
        case owner, appIdentity, processIdentity, direction, transportProtocol, endpoint
        case winningRuleID, affectingRuleIDs
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
