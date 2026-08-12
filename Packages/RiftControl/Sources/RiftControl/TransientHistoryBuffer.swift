import RiftIPC
import Foundation

public struct TransientHistoryReplay: Sendable, Hashable {
    public let batches: [RuntimeEventBatch]
    public let failureInterval: HistoryCoverageInterval?
    public let wasTruncated: Bool

    public init(
        batches: [RuntimeEventBatch],
        failureInterval: HistoryCoverageInterval?,
        wasTruncated: Bool
    ) {
        self.batches = batches
        self.failureInterval = failureInterval
        self.wasTruncated = wasTruncated
    }
}

public struct TransientHistoryBuffer: Sendable {
    public static let maximumFlows = 1_000
    public static let maximumReplayEvents = 2_000

    private struct Closure: Sendable {
        var observedAt: Date
        var closedAt: Date?
        var bytesInbound: UInt64?
        var bytesOutbound: UInt64?
        var endReason: RuntimeFlowEndReason?
    }

    private var rows: [String: MonitorEventRow] = [:]
    private var closures: [String: Closure] = [:]
    private var replayEvents: [String: RuntimeEvent] = [:]
    private var replayStartedAt: Date?
    private var replayEndedAt: Date?
    private var replayWasTruncated = false

    public init() {}

    public mutating func ingest(_ batch: RuntimeEventBatch) {
        for event in batch.events {
            let key = Self.key(event)
            switch event.kind {
            case .decision:
                let closure = closures.removeValue(forKey: key)
                rows[key] = MonitorEventRow(
                    event: event,
                    coverage: .gap,
                    closedAt: closure?.closedAt,
                    bytesInbound: closure?.bytesInbound,
                    bytesOutbound: closure?.bytesOutbound,
                    flowEndReason: closure?.endReason
                )
            case .statistics, .closed:
                var closure = closures[key] ?? Closure(observedAt: event.occurredAt)
                closure.observedAt = max(closure.observedAt, event.occurredAt)
                if event.kind == .closed { closure.closedAt = event.occurredAt }
                closure.bytesInbound = Self.maximum(closure.bytesInbound, event.bytesInbound)
                closure.bytesOutbound = Self.maximum(closure.bytesOutbound, event.bytesOutbound)
                closure.endReason = event.flowEndReason ?? closure.endReason
                closures[key] = closure
                if let row = rows[key] {
                    rows[key] = MonitorEventRow(
                        event: row.event,
                        coverage: .gap,
                        closedAt: closure.closedAt,
                        bytesInbound: closure.bytesInbound,
                        bytesOutbound: closure.bytesOutbound,
                        flowEndReason: closure.endReason
                    )
                }
            }
        }
        trim()
    }

    public mutating func retainForReplay(
        _ batch: RuntimeEventBatch,
        observedAt: Date = Date()
    ) {
        ingest(batch)
        let earliest = min(batch.events.map(\.occurredAt).min() ?? observedAt, observedAt)
        let latest = max(batch.events.map(\.occurredAt).max() ?? observedAt, observedAt)
        replayStartedAt = min(replayStartedAt ?? earliest, earliest)
        replayEndedAt = max(replayEndedAt ?? latest, latest)
        for event in batch.events.prefix(IPCProtocolLimits.maximumEventBatchCount) {
            replayEvents[Self.replayKey(event)] = event
        }
        trimReplay()
    }

    public var hasPendingReplay: Bool { replayStartedAt != nil }

    public var pendingReplayInterval: HistoryCoverageInterval? {
        guard let replayStartedAt, let replayEndedAt else { return nil }
        return HistoryCoverageInterval(
            startedAt: replayStartedAt,
            endedAt: replayEndedAt,
            reason: .appWriteFailure
        )
    }

    public func replaySnapshot() -> TransientHistoryReplay {
        let sorted = replayEvents.values.sorted {
            if $0.providerEpoch != $1.providerEpoch {
                return $0.providerEpoch.uuidString < $1.providerEpoch.uuidString
            }
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
            return $0.sequence < $1.sequence
        }
        let grouped = Dictionary(grouping: sorted, by: \.providerEpoch)
        var batches: [RuntimeEventBatch] = []
        for epoch in grouped.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let events = grouped[epoch] ?? []
            var start = 0
            while start < events.count {
                let end = min(events.count, start + IPCProtocolLimits.maximumEventBatchCount)
                batches.append(RuntimeEventBatch(
                    providerEpoch: epoch,
                    events: Array(events[start..<end]),
                    droppedCount: 0
                ))
                start = end
            }
        }
        return TransientHistoryReplay(
            batches: batches,
            failureInterval: pendingReplayInterval,
            wasTruncated: replayWasTruncated
        )
    }

    public func page(limit: Int = 500, offset: Int = 0) -> [MonitorEventRow] {
        let sorted = rows.values.sorted {
            if $0.event.occurredAt != $1.event.occurredAt {
                return $0.event.occurredAt > $1.event.occurredAt
            }
            return $0.id > $1.id
        }
        let start = min(max(0, offset), sorted.count)
        let end = min(sorted.count, start + min(max(1, limit), Self.maximumFlows))
        return Array(sorted[start..<end])
    }

    public mutating func clear() {
        clearDisplay()
        replayEvents.removeAll(keepingCapacity: true)
        replayStartedAt = nil
        replayEndedAt = nil
        replayWasTruncated = false
    }

    public mutating func clearDisplay() {
        rows.removeAll(keepingCapacity: true)
        closures.removeAll(keepingCapacity: true)
    }

    private mutating func trim() {
        if rows.count > Self.maximumFlows {
            let removeCount = rows.count - Self.maximumFlows
            let oldest = rows.sorted {
                $0.value.event.occurredAt < $1.value.event.occurredAt
            }.prefix(removeCount).map(\.key)
            for key in oldest {
                rows.removeValue(forKey: key)
                closures.removeValue(forKey: key)
            }
        }
        if closures.count > Self.maximumFlows {
            let removeCount = closures.count - Self.maximumFlows
            let oldest = closures.sorted {
                $0.value.observedAt < $1.value.observedAt
            }.prefix(removeCount).map(\.key)
            for key in oldest { closures.removeValue(forKey: key) }
        }
    }

    private mutating func trimReplay() {
        guard replayEvents.count > Self.maximumReplayEvents else { return }
        let removeCount = replayEvents.count - Self.maximumReplayEvents
        let oldest = replayEvents.sorted {
            if $0.value.occurredAt != $1.value.occurredAt {
                return $0.value.occurredAt < $1.value.occurredAt
            }
            return $0.key < $1.key
        }.prefix(removeCount).map(\.key)
        for key in oldest { replayEvents.removeValue(forKey: key) }
        replayWasTruncated = true
    }

    private static func key(_ event: RuntimeEvent) -> String {
        "\(event.providerEpoch.uuidString.lowercased())|\(event.flow.flowID.uuidString.lowercased())"
    }

    private static func replayKey(_ event: RuntimeEvent) -> String {
        "\(event.providerEpoch.uuidString.lowercased())|\(event.sequence)"
    }

    private static func maximum(_ lhs: UInt64?, _ rhs: UInt64?) -> UInt64? {
        switch (lhs, rhs) {
        case (.none, .none): nil
        case (.some(let value), .none), (.none, .some(let value)): value
        case (.some(let lhs), .some(let rhs)): max(lhs, rhs)
        }
    }
}
