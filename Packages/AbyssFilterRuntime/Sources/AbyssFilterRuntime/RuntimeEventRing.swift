import AbyssIPC
import Foundation

public final class RuntimeEventRing: @unchecked Sendable {
    public static let maximumEntries = 4_096

    private let lock = NSLock()
    private var providerEpoch: UUID?
    private var lastProviderEpoch: UUID?
    private var nextSequence: UInt64 = 1
    private var droppedCount: UInt64 = 0
    private var events: [RuntimeEvent] = []
    private var activitySignal: (@Sendable () -> Void)?

    public init() {}

    public func installActivitySignal(_ signal: @escaping @Sendable () -> Void) {
        lock.withLock { activitySignal = signal }
    }

    public func activate(providerEpoch: UUID) {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            if self.providerEpoch == providerEpoch {
                return events.isEmpty ? nil : activitySignal
            }
            let epochChanged = lastProviderEpoch.map { $0 != providerEpoch } ?? false
            self.providerEpoch = providerEpoch
            if epochChanged {
                nextSequence = 1
                recordLoss()
            } else if lastProviderEpoch == nil {
                nextSequence = 1
            }
            lastProviderEpoch = providerEpoch
            return epochChanged || !events.isEmpty ? activitySignal : nil
        }
        signal?()
    }

    public func deactivate(providerEpoch: UUID) {
        lock.withLock {
            guard self.providerEpoch == providerEpoch else { return }
            self.providerEpoch = nil
        }
    }

    public func append(_ seed: RuntimeEventSeed) {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let providerEpoch else { return nil }
            let event = RuntimeEvent(
                providerEpoch: providerEpoch,
                sequence: nextSequence,
                kind: seed.kind,
                occurredAt: seed.occurredAt,
                flow: seed.flow,
                action: seed.action,
                reason: seed.reason,
                policy: seed.policy,
                winningRuleID: seed.winningRuleID,
                affectingRuleIDs: seed.affectingRuleIDs,
                explanation: seed.explanation,
                bytesInbound: seed.bytesInbound,
                bytesOutbound: seed.bytesOutbound,
                flowEndReason: seed.flowEndReason,
                notificationRequested: seed.notificationRequested
            )
            nextSequence &+= 1
            if events.count >= Self.maximumEntries {
                guard let index = evictionIndex(for: event.kind) else {
                    recordLoss()
                    return activitySignal
                }
                events.remove(at: index)
                recordLoss()
            }
            events.append(event)
            return activitySignal
        }
        signal?()
    }

    public func recordAnonymousLoss(_ count: UInt64 = 1) {
        guard count > 0 else { return }
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            recordLoss(count)
            return activitySignal
        }
        signal?()
    }

    public func drain(maximumCount: Int = IPCProtocolLimits.maximumEventBatchCount) -> RuntimeEventBatch {
        lock.withLock {
            let count = min(max(0, maximumCount), events.count)
            let result = Array(events.prefix(count))
            events.removeFirst(count)
            return RuntimeEventBatch(
                providerEpoch: providerEpoch,
                events: result,
                droppedCount: droppedCount
            )
        }
    }

    static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (result, overflow) = value.addingReportingOverflow(increment)
        return overflow ? .max : result
    }

    private func recordLoss(_ count: UInt64 = 1) {
        droppedCount = Self.saturatingAdd(droppedCount, count)
    }

    private func evictionIndex(for incomingKind: RuntimeEventKind) -> Int? {
        let incomingPriority = incomingKind.retentionPriority
        var candidate: (index: Int, priority: Int)?
        for (index, event) in events.enumerated() {
            let priority = event.kind.retentionPriority
            guard priority <= incomingPriority else { continue }
            if candidate == nil || priority < candidate!.priority {
                candidate = (index, priority)
                if priority == RuntimeEventKind.statistics.retentionPriority { break }
            }
        }
        return candidate?.index
    }
}

private extension RuntimeEventKind {
    var retentionPriority: Int {
        switch self {
        case .statistics: 0
        case .closed: 1
        case .decision: 2
        }
    }
}
