import RiftIPC
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
    private var attentionSignal: (@Sendable () -> Void)?
    private var captureChanged: (@Sendable () -> Void)?
    private var recentExpired: (@Sendable ([UUID]) -> Void)?
    private var subscription = ActivitySubscription(mode: .persistent)
    private struct Recent {
        var decision: RuntimeEvent?
        var lifecycle: RuntimeEvent?
        let observedAt: Date
    }
    private var recent: [UUID: Recent] = [:]
    private var recentRevision: UInt64 = 0
    private var recentWasTruncated = false
    private var recentDenyAt: Date?

    public init() {}

    public func installActivitySignal(_ signal: @escaping @Sendable () -> Void) {
        lock.withLock { activitySignal = signal }
    }

    public func installAttentionSignal(_ signal: @escaping @Sendable () -> Void) {
        lock.withLock { attentionSignal = signal }
    }

    public func installCaptureChangeHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { captureChanged = handler }
    }

    public func installRecentExpiryHandler(_ handler: @escaping @Sendable ([UUID]) -> Void) {
        lock.withLock { recentExpired = handler }
    }

    public var captureMode: ActivityCaptureMode { lock.withLock { subscription.mode } }
    public var recentCapacity: Int { lock.withLock { subscription.maximumRecentConnections } }
    public var notifyImplicitDecisions: Bool { lock.withLock { subscription.notifyImplicitDecisions } }

    public func configure(_ value: ActivitySubscription) {
        guard value.isValid else { return }
        let changed = lock.withLock { () -> (@Sendable () -> Void)? in
            guard subscription != value else { return nil }
            if subscription.mode == .persistent, value.mode == .persistent {
                subscription = value
                return nil
            }
            subscription = value
            events.removeAll(keepingCapacity: false)
            recent.removeAll(keepingCapacity: false)
            recentWasTruncated = false
            recentRevision &+= 1
            return captureChanged
        }
        changed?()
    }

    public func shouldReport(flowID: UUID) -> Bool {
        lock.withLock {
            switch subscription.mode {
            case .off: false
            case .persistent: true
            case .recent: recent[flowID] != nil
            }
        }
    }

    public func noteDeny(at date: Date) {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            guard providerEpoch != nil else { return nil }
            recentDenyAt = max(recentDenyAt ?? date, date)
            return attentionSignal
        }
        signal?()
    }

    public func takeRecentDeny() -> Date? {
        lock.withLock {
            defer { recentDenyAt = nil }
            return recentDenyAt
        }
    }

    public func recentSnapshot(now: Date = Date()) -> RecentActivitySnapshot {
        let (snapshot, expired, handler) = lock.withLock {
            let expired = pruneRecent(now: now)
            let values = recent.values.sorted { $0.observedAt > $1.observedAt }
            let snapshot = RecentActivitySnapshot(
                subscriptionID: subscription.id, providerEpoch: providerEpoch,
                revision: recentRevision,
                events: values.flatMap { [$0.decision, $0.lifecycle].compactMap { $0 } },
                isTruncated: recentWasTruncated,
                nextExpiry: values.map { $0.observedAt.addingTimeInterval(ActivitySubscription.recentLifetime) }.min()
            )
            return (snapshot, expired, recentExpired)
        }
        if !expired.isEmpty { handler?(expired) }
        return snapshot
    }

    public func activate(providerEpoch: UUID) {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            if self.providerEpoch == providerEpoch {
                return events.isEmpty ? nil : activitySignal
            }
            let epochChanged = lastProviderEpoch.map { $0 != providerEpoch } ?? false
            self.providerEpoch = providerEpoch
            recent.removeAll(keepingCapacity: false)
            recentDenyAt = nil
            recentRevision &+= 1
            if epochChanged {
                nextSequence = 1
                if subscription.mode == .persistent { recordLoss() }
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
            recent.removeAll(keepingCapacity: false)
            recentDenyAt = nil
        }
    }

    public func append(_ seed: RuntimeEventSeed) {
        var removedFlows: [UUID] = []
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let providerEpoch, subscription.mode != .off else { return nil }
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
            if subscription.mode == .recent {
                removedFlows = pruneRecent(now: event.occurredAt)
                guard event.flow.observedAt.addingTimeInterval(ActivitySubscription.recentLifetime) > event.occurredAt else { return nil }
                let key = event.flow.flowID
                var value = recent[key] ?? Recent(observedAt: event.flow.observedAt)
                if event.kind == .decision { value.decision = event }
                else { value.lifecycle = Self.mergeLifecycle(value.lifecycle, event) }
                recent[key] = value
                while recent.count > subscription.maximumRecentConnections,
                      let oldest = recent.min(by: { $0.value.observedAt < $1.value.observedAt })?.key {
                    recent.removeValue(forKey: oldest)
                    removedFlows.append(oldest)
                    recentWasTruncated = true
                }
                recentRevision &+= 1
                return activitySignal
            }
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
        if !removedFlows.isEmpty { lock.withLock { recentExpired }?(removedFlows) }
        signal?()
    }

    public func recordAnonymousLoss(_ count: UInt64 = 1) {
        guard count > 0 else { return }
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            guard subscription.mode == .persistent else { return nil }
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

    private func pruneRecent(now: Date) -> [UUID] {
        let expired = recent.filter { $0.value.observedAt.addingTimeInterval(ActivitySubscription.recentLifetime) <= now }.map(\.key)
        guard !expired.isEmpty else { return [] }
        for key in expired { recent.removeValue(forKey: key) }
        recentWasTruncated = true
        recentRevision &+= 1
        return expired
    }

    private static func mergeLifecycle(_ prior: RuntimeEvent?, _ event: RuntimeEvent) -> RuntimeEvent {
        guard let prior else { return event }
        let base: RuntimeEvent
        if prior.kind == .closed {
            base = event.kind != .closed || prior.occurredAt >= event.occurredAt ? prior : event
        } else {
            base = event.kind == .closed || event.occurredAt >= prior.occurredAt ? event : prior
        }
        func maximum(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
            if let lhs, let rhs { return max(lhs, rhs) }
            return lhs ?? rhs
        }
        return RuntimeEvent(
            providerEpoch: base.providerEpoch, sequence: base.sequence, kind: base.kind,
            occurredAt: base.occurredAt, flow: base.flow, action: base.action, reason: base.reason,
            policy: base.policy, winningRuleID: base.winningRuleID, affectingRuleIDs: base.affectingRuleIDs,
            explanation: base.explanation,
            bytesInbound: maximum(prior.bytesInbound, event.bytesInbound),
            bytesOutbound: maximum(prior.bytesOutbound, event.bytesOutbound),
            flowEndReason: base.flowEndReason, notificationRequested: base.notificationRequested
        )
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
