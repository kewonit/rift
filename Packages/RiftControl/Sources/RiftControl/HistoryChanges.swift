import Foundation

public struct HistoryFlowKey: Sendable, Hashable {
    public let providerEpoch: UUID
    public let flowID: UUID

    public init(providerEpoch: UUID, flowID: UUID) {
        self.providerEpoch = providerEpoch
        self.flowID = flowID
    }
}

public struct MonitorDecisionKey: Sendable, Hashable {
    public let providerEpoch: UUID
    public let sequence: UInt64

    public init(providerEpoch: UUID, sequence: UInt64) {
        self.providerEpoch = providerEpoch
        self.sequence = sequence
    }
}

public extension MonitorEventRow {
    var flowKey: HistoryFlowKey {
        HistoryFlowKey(providerEpoch: event.providerEpoch, flowID: event.flow.flowID)
    }

    var decisionKey: MonitorDecisionKey {
        MonitorDecisionKey(providerEpoch: event.providerEpoch, sequence: event.sequence)
    }
}

public struct HistoryChangeCursor: Sendable, Hashable {
    let repositoryID: UUID
    let revision: UInt64
}

public struct HistoryMonitorDelta: Sendable {
    public let cursor: HistoryChangeCursor
    public let updatedRows: [MonitorEventRow]
    public let removedFlowKeys: Set<HistoryFlowKey>
    public let coverage: HistoryCoverageSnapshot
    public let requiresFullRefresh: Bool
}

struct HistoryChangeJournal {
    private var repositoryID = UUID()
    private var revision: UInt64 = 0
    private var commits: [(revision: UInt64, keys: Set<HistoryFlowKey>)] = []
    private var keyCount = 0

    var cursor: HistoryChangeCursor {
        HistoryChangeCursor(repositoryID: repositoryID, revision: revision)
    }

    mutating func reset() {
        repositoryID = UUID()
        revision = 0
        commits.removeAll(keepingCapacity: true)
        keyCount = 0
    }

    mutating func record(_ keys: Set<HistoryFlowKey>) {
        revision += 1
        commits.append((revision, keys))
        keyCount += keys.count
        while commits.count > 256 || keyCount > 8_192 {
            keyCount -= commits.removeFirst().keys.count
        }
    }

    func changes(after cursor: HistoryChangeCursor) -> Set<HistoryFlowKey>? {
        guard cursor.repositoryID == repositoryID, cursor.revision <= revision else { return nil }
        if cursor.revision == revision { return [] }
        guard let first = commits.first, cursor.revision >= first.revision - 1 else { return nil }
        return commits.lazy.filter { $0.revision > cursor.revision }
            .reduce(into: Set<HistoryFlowKey>()) { $0.formUnion($1.keys) }
    }
}

public enum MonitorHistoryMerge {
    public static func applying(
        _ delta: HistoryMonitorDelta,
        to snapshot: HistoryMonitorSnapshot,
        window: MonitorTimeWindow? = nil,
        maximum: Int = 50_000
    ) async throws -> HistoryMonitorSnapshot {
        try await MonitorQueryWorker.run(priority: .utility) {
            var updates = Dictionary(uniqueKeysWithValues: delta.updatedRows.map { ($0.flowKey, $0) })
            let coverageChanged = snapshot.coverage != delta.coverage
            let coverageIndex = HistoryCoverageIndex(delta.coverage)
            var retained: [MonitorEventRow] = []
            retained.reserveCapacity(snapshot.rows.count + updates.count)
            var sortNeeded = false
            for (index, original) in snapshot.rows.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                let key = original.flowKey
                let updated = updates.removeValue(forKey: key)
                guard !delta.removedFlowKeys.contains(key) else { continue }
                let row = updated ?? original
                guard window?.contains(row.event.occurredAt) ?? true else { continue }
                if let updated, updated.event.sequence != original.event.sequence
                    || updated.event.occurredAt != original.event.occurredAt { sortNeeded = true }
                if coverageChanged {
                    let range = coverageIndex.coverage(
                        from: row.event.occurredAt,
                        to: max(row.closedAt ?? row.event.occurredAt, row.event.occurredAt)
                            .addingTimeInterval(0.001)
                    )
                    let legacy = row.bytesInbound == UInt64(Int64.max)
                        || row.bytesOutbound == UInt64(Int64.max)
                    retained.append(MonitorEventRow(
                        event: row.event, coverage: legacy ? .combined(range, .partial) : range,
                        closedAt: row.closedAt, bytesInbound: row.bytesInbound,
                        bytesOutbound: row.bytesOutbound, flowEndReason: row.flowEndReason
                    ))
                } else { retained.append(row) }
            }
            for row in updates.values where window?.contains(row.event.occurredAt) ?? true {
                retained.append(row)
                sortNeeded = true
            }
            if sortNeeded { retained.sort(by: moreRecent) }
            try Task.checkCancellation()
            let bound = min(max(1, maximum), 50_000)
            return HistoryMonitorSnapshot(
                rows: Array(retained.prefix(bound)),
                isComplete: snapshot.isComplete && retained.count <= bound,
                coverage: delta.coverage, cursor: delta.cursor
            )
        }
    }

    static func moreRecent(_ lhs: MonitorEventRow, _ rhs: MonitorEventRow) -> Bool {
        if lhs.event.occurredAt != rhs.event.occurredAt {
            return lhs.event.occurredAt > rhs.event.occurredAt
        }
        if lhs.event.sequence != rhs.event.sequence { return Int64(bitPattern: lhs.event.sequence) > Int64(bitPattern: rhs.event.sequence) }
        if lhs.event.providerEpoch != rhs.event.providerEpoch {
            return lhs.event.providerEpoch.uuidString > rhs.event.providerEpoch.uuidString
        }
        return lhs.event.flow.flowID.uuidString > rhs.event.flow.flowID.uuidString
    }
}
