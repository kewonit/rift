import RiftCore
import RiftIPC
import Foundation

public struct PromptSeed: Sendable {
    public let lineageID: UUID
    public let generation: UInt64
    public let flow: FlowDescriptor
    public let winningRuleID: UUID?
    public let affectingRuleIDs: [UUID]

    public init(
        lineageID: UUID,
        generation: UInt64,
        flow: FlowDescriptor,
        winningRuleID: UUID?,
        affectingRuleIDs: [UUID]
    ) {
        self.lineageID = lineageID
        self.generation = generation
        self.flow = flow
        self.winningRuleID = winningRuleID
        self.affectingRuleIDs = affectingRuleIDs
    }
}

public struct PromptCohortKey: Sendable, Hashable {
    private let lineageID: UUID
    private let generation: UInt64
    private let owner: FlowOwner
    private let appIdentity: ProcessIdentity?
    private let processIdentity: ProcessIdentity?
    private let direction: TrafficDirection
    private let transportProtocol: TransportProtocol
    private let endpoint: Endpoint?

    public init(lineageID: UUID, generation: UInt64, flow: FlowDescriptor) {
        self.lineageID = lineageID
        self.generation = generation
        self.owner = flow.owner
        self.appIdentity = flow.sourceAppIdentity
        self.processIdentity = flow.sourceProcessIdentity
        self.direction = flow.direction
        self.transportProtocol = flow.transportProtocol
        self.endpoint = flow.destinationEndpoint
    }
}

public enum PromptResolution: Sendable, Equatable {
    case answered(FilterAction)
    case unavailableFallback
    case deadlineFallback
}

public enum PromptQueueError: Error, Sendable, Equatable {
    case unavailable
    case capacityReached
    case invalidLease
    case staleAnswer
}

public final class PromptQueue: @unchecked Sendable {
    public static let maximumEntries = 256
    public static let maximumDrainCount = 32

    private struct Controller {
        let leaseID: UUID
        let providerEpoch: UUID
    }

    private struct Entry {
        var request: PromptRequest
        var deadline: Date
        let completion: @Sendable (PromptResolution) -> Void
        var delivered: Bool
    }

    private let lock = NSLock()
    private var controller: Controller?
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var activitySignal: (@Sendable () -> Void)?

    public init() {}

    public func installActivitySignal(_ signal: @escaping @Sendable () -> Void) {
        lock.withLock { activitySignal = signal }
    }

    public func activate(controllerLeaseID: UUID, providerEpoch: UUID?) {
        let fallbacks = lock.withLock { () -> [@Sendable (PromptResolution) -> Void] in
            let old = entries.values.map(\.completion)
            entries.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            controller = providerEpoch.map {
                Controller(leaseID: controllerLeaseID, providerEpoch: $0)
            }
            return old
        }
        fallbacks.forEach { $0(.unavailableFallback) }
    }

    public func deactivate(controllerLeaseID: UUID) {
        let fallbacks = lock.withLock { () -> [@Sendable (PromptResolution) -> Void] in
            guard controller?.leaseID == controllerLeaseID else { return [] }
            controller = nil
            let values = entries.values.map(\.completion)
            entries.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            return values
        }
        fallbacks.forEach { $0(.unavailableFallback) }
    }

    public func enqueue(
        _ seed: PromptSeed,
        deadline: Date,
        completion: @escaping @Sendable (PromptResolution) -> Void
    ) throws -> UUID {
        let nonce = try lock.withLock {
            guard let controller else { throw PromptQueueError.unavailable }
            guard entries.count < Self.maximumEntries else { throw PromptQueueError.capacityReached }
            let nonce = UUID()
            let request = PromptRequest(
                nonce: nonce,
                providerEpoch: controller.providerEpoch,
                lineageID: seed.lineageID,
                generation: seed.generation,
                flowID: seed.flow.flowID,
                observedAt: seed.flow.observedAt,
                deadline: deadline,
                owner: seed.flow.owner,
                appIdentity: seed.flow.sourceAppIdentity,
                processIdentity: seed.flow.sourceProcessIdentity,
                direction: seed.flow.direction,
                transportProtocol: seed.flow.transportProtocol,
                endpoint: seed.flow.destinationEndpoint,
                winningRuleID: seed.winningRuleID,
                affectingRuleIDs: Array(seed.affectingRuleIDs.prefix(256))
            )
            entries[nonce] = Entry(
                request: request,
                deadline: deadline,
                completion: completion,
                delivered: false
            )
            order.append(nonce)
            return nonce
        }
        lock.withLock { activitySignal }?()
        return nonce
    }

    public func drain(controllerLeaseID: UUID) throws -> [PromptRequest] {
        try lock.withLock {
            guard controller?.leaseID == controllerLeaseID else { throw PromptQueueError.invalidLease }
            let now = Date()
            var result: [PromptRequest] = []
            for nonce in order where result.count < Self.maximumDrainCount {
                guard var entry = entries[nonce], !entry.delivered, entry.deadline > now else { continue }
                entry.delivered = true
                entries[nonce] = entry
                result.append(entry.request)
            }
            return result
        }
    }

    @discardableResult
    public func updateCohort(_ nonce: UUID, deadline: Date, count: UInt16) -> Bool {
        let boundedCount = min(max(count, 1), PromptRequest.maximumCohortCount)
        let result = lock.withLock { () -> (exists: Bool, changed: Bool) in
            guard var entry = entries[nonce] else { return (false, false) }
            let earliestDeadline = min(deadline, entry.deadline)
            guard earliestDeadline != entry.deadline
                    || boundedCount != entry.request.cohortCount else {
                return (true, false)
            }
            entry.deadline = earliestDeadline
            entry.request = entry.request.updated(
                deadline: earliestDeadline,
                cohortCount: boundedCount
            )
            entry.delivered = false
            entries[nonce] = entry
            return (true, true)
        }
        if result.changed { lock.withLock { activitySignal }?() }
        return result.exists
    }

    public func answer(_ answer: PromptAnswer, controllerLeaseID: UUID) throws {
        let completion = try lock.withLock { () -> (@Sendable (PromptResolution) -> Void) in
            guard controller?.leaseID == controllerLeaseID else { throw PromptQueueError.invalidLease }
            guard let entry = entries[answer.nonce],
                  entry.request.providerEpoch == answer.providerEpoch,
                  entry.request.lineageID == answer.lineageID,
                  entry.request.generation == answer.generation,
                  entry.deadline > Date() else { throw PromptQueueError.staleAnswer }
            entries.removeValue(forKey: answer.nonce)
            order.removeAll { $0 == answer.nonce }
            return entry.completion
        }
        completion(.answered(answer.action))
    }

    @discardableResult
    public func expire(_ nonce: UUID, now: Date = Date()) -> Bool {
        let completion = lock.withLock { () -> (@Sendable (PromptResolution) -> Void)? in
            guard let entry = entries[nonce], entry.deadline <= now else { return nil }
            entries.removeValue(forKey: nonce)
            order.removeAll { $0 == nonce }
            return entry.completion
        }
        guard let completion else { return false }
        completion(.deadlineFallback)
        return true
    }

    public func cancel(_ nonce: UUID) {
        lock.withLock {
            entries.removeValue(forKey: nonce)
            order.removeAll { $0 == nonce }
        }
    }
}

private extension PromptRequest {
    func updated(deadline: Date, cohortCount: UInt16) -> PromptRequest {
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
            affectingRuleIDs: affectingRuleIDs
        )
    }
}
