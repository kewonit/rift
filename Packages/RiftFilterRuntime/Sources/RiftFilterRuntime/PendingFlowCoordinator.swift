import RiftCore
import Foundation

public struct PendingFlowKey: Sendable, Hashable {
    public let lineageID: UUID
    public let generation: UInt64
    public let owner: FlowOwner
    public let appIdentity: ProcessIdentity?
    public let direction: TrafficDirection
    public let endpoint: Endpoint?
    public let transportProtocol: TransportProtocol

    public init(
        lineageID: UUID,
        generation: UInt64,
        owner: FlowOwner,
        appIdentity: ProcessIdentity?,
        direction: TrafficDirection,
        endpoint: Endpoint?,
        transportProtocol: TransportProtocol
    ) {
        self.lineageID = lineageID
        self.generation = generation
        self.owner = owner
        self.appIdentity = appIdentity
        self.direction = direction
        self.endpoint = endpoint
        self.transportProtocol = transportProtocol
    }
}

public enum PendingFlowState: Sendable, Hashable {
    case resolvingIdentity
    case awaitingUser(nonce: UUID)
}

public struct PendingRegistration: Sendable, Hashable {
    public let cohortID: UUID
    public let nonce: UUID?
    public let isNewCohort: Bool
}

public enum PendingFlowCoordinatorError: Error, Sendable, Equatable {
    case capacityReached
    case duplicateFlow
    case missingCohort
    case alreadyResumed
}

public actor PendingFlowCoordinator {
    public static let maximumCohorts = 256
    public static let maximumFlowsPerCohort = 64

    private struct Cohort: Sendable {
        let id: UUID
        let key: PendingFlowKey
        let deadline: Date
        var state: PendingFlowState
        var flowIDs: Set<UUID>

        var nonce: UUID? {
            if case .awaitingUser(let nonce) = state { return nonce }
            return nil
        }
    }

    private var cohorts: [PendingFlowKey: Cohort] = [:]
    private var cohortKeyByFlowID: [UUID: PendingFlowKey] = [:]
    private var resumedFlowIDs: Set<UUID> = []

    public init() {}

    public func register(
        flowID: UUID,
        key: PendingFlowKey,
        initialState: PendingFlowState,
        deadline: Date
    ) throws -> PendingRegistration {
        guard cohortKeyByFlowID[flowID] == nil, !resumedFlowIDs.contains(flowID) else {
            throw PendingFlowCoordinatorError.duplicateFlow
        }
        if var existing = cohorts[key] {
            guard existing.flowIDs.count < Self.maximumFlowsPerCohort else {
                throw PendingFlowCoordinatorError.capacityReached
            }
            existing.flowIDs.insert(flowID)
            cohorts[key] = existing
            cohortKeyByFlowID[flowID] = key
            return PendingRegistration(
                cohortID: existing.id,
                nonce: existing.nonce,
                isNewCohort: false
            )
        }
        guard cohorts.count < Self.maximumCohorts else {
            throw PendingFlowCoordinatorError.capacityReached
        }
        let cohort = Cohort(
            id: UUID(),
            key: key,
            deadline: deadline,
            state: initialState,
            flowIDs: [flowID]
        )
        cohorts[key] = cohort
        cohortKeyByFlowID[flowID] = key
        return PendingRegistration(cohortID: cohort.id, nonce: cohort.nonce, isNewCohort: true)
    }

    public func transitionToAwaitingUser(cohortID: UUID) throws -> UUID {
        guard let entry = cohorts.first(where: { $0.value.id == cohortID }) else {
            throw PendingFlowCoordinatorError.missingCohort
        }
        let nonce = UUID()
        var cohort = entry.value
        cohort.state = .awaitingUser(nonce: nonce)
        cohorts[entry.key] = cohort
        return nonce
    }

    public func resolve(cohortID: UUID) throws -> [UUID] {
        guard let entry = cohorts.first(where: { $0.value.id == cohortID }) else {
            throw PendingFlowCoordinatorError.missingCohort
        }
        cohorts.removeValue(forKey: entry.key)
        for flowID in entry.value.flowIDs {
            cohortKeyByFlowID.removeValue(forKey: flowID)
            guard resumedFlowIDs.insert(flowID).inserted else {
                throw PendingFlowCoordinatorError.alreadyResumed
            }
        }
        return entry.value.flowIDs.sorted { $0.uuidString < $1.uuidString }
    }

    public func expire(at now: Date) -> [UUID] {
        let expired = cohorts.values.filter { $0.deadline <= now }.map(\.id)
        return expired.flatMap { (try? resolve(cohortID: $0)) ?? [] }
    }

    public func resolveAll() -> [UUID] {
        let identifiers = cohorts.values.map(\.id)
        return identifiers.flatMap { (try? resolve(cohortID: $0)) ?? [] }
    }

    public func pendingCounts() -> (cohorts: Int, flows: Int) {
        (cohorts.count, cohortKeyByFlowID.count)
    }
}
