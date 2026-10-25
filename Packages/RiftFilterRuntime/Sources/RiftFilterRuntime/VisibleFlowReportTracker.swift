import RiftCore
import RiftIPC
import Foundation

public enum VisibleFlowRetentionResult: Sendable, Equatable {
    case retained
    case notTrackable
    case capacityExceeded
}

public final class VisibleFlowReportTracker: @unchecked Sendable {
    public static let maximumEntries = 4_096

    private let lock = NSLock()
    private let maximumEntries: Int
    private var decisions: [UUID: RuntimeEventSeed] = [:]

    public init(maximumEntries: Int = VisibleFlowReportTracker.maximumEntries) {
        self.maximumEntries = max(1, maximumEntries)
    }

    @discardableResult
    public func retain(
        flowID: UUID,
        decision: RuntimeEventSeed
    ) -> VisibleFlowRetentionResult {
        guard decision.action == .allow else { return .notTrackable }
        return lock.withLock {
            if decisions[flowID] != nil { return .retained }
            guard decisions.count < maximumEntries else { return .capacityExceeded }
            decisions[flowID] = decision
            return .retained
        }
    }

    public func decision(flowID: UUID) -> RuntimeEventSeed? {
        lock.withLock { decisions[flowID] }
    }

    public func retainRecent(flowID: UUID, decision: RuntimeEventSeed, maximum: Int, now: Date) {
        guard decision.action == .allow else { return }
        lock.withLock {
            decisions = decisions.filter { $0.value.flow.observedAt.addingTimeInterval(ActivitySubscription.recentLifetime) > now }
            decisions[flowID] = decision
            while decisions.count > maximum,
                  let oldest = decisions.min(by: { $0.value.flow.observedAt < $1.value.flow.observedAt })?.key {
                decisions.removeValue(forKey: oldest)
            }
        }
    }

    public func take(flowID: UUID) -> RuntimeEventSeed? {
        lock.withLock { decisions.removeValue(forKey: flowID) }
    }

    public func remove(flowIDs: [UUID]) {
        lock.withLock { for id in flowIDs { decisions.removeValue(forKey: id) } }
    }

    public func takeAll() -> [RuntimeEventSeed] {
        lock.withLock {
            defer { decisions.removeAll(keepingCapacity: false) }
            return Array(decisions.values)
        }
    }
}
