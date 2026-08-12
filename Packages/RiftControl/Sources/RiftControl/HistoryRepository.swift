import RiftCore
import RiftIPC
import Foundation
import GRDB

public struct HistorySettings: Sendable, Hashable {
    public let enabled: Bool
    public let retentionDays: Int
    public let maximumFlows: Int
}

public enum HistoryCoverage: String, Sendable, Hashable, Codable {
    case complete
    case partial
    case gap
}

public struct MonitorEventRow: Sendable, Hashable, Identifiable {
    public var id: String { "\(event.providerEpoch.uuidString)-\(event.sequence)" }
    public let event: RuntimeEvent
    public let coverage: HistoryCoverage
    public let closedAt: Date?
    public let bytesInbound: UInt64?
    public let bytesOutbound: UInt64?
    public let flowEndReason: RuntimeFlowEndReason?

    public init(
        event: RuntimeEvent,
        coverage: HistoryCoverage,
        closedAt: Date? = nil,
        bytesInbound: UInt64? = nil,
        bytesOutbound: UInt64? = nil,
        flowEndReason: RuntimeFlowEndReason? = nil
    ) {
        self.event = event
        self.coverage = coverage
        self.closedAt = closedAt
        self.bytesInbound = bytesInbound
        self.bytesOutbound = bytesOutbound
        self.flowEndReason = flowEndReason
    }
}

public struct HistoryMonitorSnapshot: Sendable, Hashable {
    public let rows: [MonitorEventRow]
    public let isComplete: Bool
    public let coverage: HistoryCoverageSnapshot

    public init(
        rows: [MonitorEventRow],
        isComplete: Bool,
        coverage: HistoryCoverageSnapshot
    ) {
        self.rows = rows
        self.isComplete = isComplete
        self.coverage = coverage
    }
}

public struct DecisionBucket: Sendable, Hashable, Identifiable {
    public var id: Date { start }
    public let start: Date
    public let allowed: Int
    public let denied: Int
    public let unresolved: Int

    public init(start: Date, allowed: Int, denied: Int, unresolved: Int) {
        self.start = start
        self.allowed = allowed
        self.denied = denied
        self.unresolved = unresolved
    }
}

public struct DecisionBucketSnapshot: Sendable, Hashable {
    public let buckets: [DecisionBucket]
    public let coverage: HistoryCoverage

    public init(buckets: [DecisionBucket], coverage: HistoryCoverage) {
        self.buckets = buckets
        self.coverage = coverage
    }
}

public struct HistoryDiagnosticCounts: Sendable, Hashable {
    public let visibleFlows: Int
    public let coverageGaps: Int

    public init(visibleFlows: Int, coverageGaps: Int) {
        self.visibleFlows = visibleFlows
        self.coverageGaps = coverageGaps
    }
}

public actor HistoryRepository {
    private let database: DatabasePool

    public init(database: DatabasePool) {
        self.database = database
    }

    public func settings() throws -> HistorySettings {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM history_settings WHERE singleton_id = 1"
            ) else {
                return HistorySettings(enabled: true, retentionDays: 30, maximumFlows: 50_000)
            }
            return HistorySettings(
                enabled: row["enabled"],
                retentionDays: row["retention_days"],
                maximumFlows: row["maximum_flows"]
            )
        }
    }

    public func configure(
        enabled: Bool,
        retentionDays: Int,
        maximumFlows: Int,
        now: Date = Date()
    ) throws {
        let days = min(max(1, retentionDays), 30)
        let flows = min(max(100, maximumFlows), 50_000)
        let next = HistorySettings(enabled: enabled, retentionDays: days, maximumFlows: flows)
        try database.write { database in
            let wasEnabled = try Bool.fetchOne(
                database,
                sql: "SELECT enabled FROM history_settings WHERE singleton_id = 1"
            ) ?? false
            try database.execute(
                sql: "UPDATE history_settings SET enabled = ?, retention_days = ?, maximum_flows = ? WHERE singleton_id = 1",
                arguments: [enabled, days, flows]
            )
            if wasEnabled && !enabled {
                try HistoryCoverageStore.markDisabled(in: database, now: now)
            } else if !wasEnabled && enabled {
                try HistoryCoverageStore.markEnabled(in: database, now: now)
            }
            try HistoryRepositoryStorage.enforceRetention(in: database, settings: next, now: now)
        }
    }

    public func recordAuthenticatedRuntimeDrain(
        runtimeInstanceID: UUID,
        at drainedAt: Date
    ) throws -> HistoryRuntimeTransition {
        let current = try settings()
        return try database.write { database in
            let transition = try HistoryRuntimeCoverageStore.recordSuccessfulDrain(
                runtimeInstanceID: runtimeInstanceID,
                at: drainedAt,
                historyEnabled: current.enabled,
                in: database
            )
            if transition.detectedRestart, current.enabled {
                try HistoryRepositoryStorage.enforceRetention(
                    in: database,
                    settings: current,
                    now: drainedAt
                )
            }
            return transition
        }
    }

    public func ingest(
        _ batch: RuntimeEventBatch,
        now: Date,
        runtimeInstanceID: UUID? = nil
    ) throws {
        try persist(
            batches: [(batch, runtimeInstanceID)],
            coverageInterval: nil,
            now: now
        )
    }

    public func ingestRecovering(
        replayBatches: [RuntimeEventBatch],
        currentBatch: RuntimeEventBatch,
        writeFailureInterval: HistoryCoverageInterval,
        now: Date,
        runtimeInstanceID: UUID? = nil
    ) throws {
        let replay = replayBatches.map { ($0, Optional<UUID>.none) }
        try persist(
            batches: replay + [(currentBatch, runtimeInstanceID)],
            coverageInterval: writeFailureInterval,
            now: now
        )
    }

    public func recordCoverageGap(_ interval: HistoryCoverageInterval, now: Date) throws {
        let current = try settings()
        try database.write { database in
            try HistoryCoverageStore.record(interval, in: database)
            try HistoryRepositoryStorage.enforceRetention(
                in: database,
                settings: current,
                now: now
            )
        }
    }

    public func page(limit: Int = 500, offset: Int = 0) throws -> [MonitorEventRow] {
        let boundedLimit = min(max(1, limit), 1_000)
        return try database.read { database in
            let coverage = try HistoryCoverageStore.snapshot(in: database)
            return try HistoryRepositoryStorage.monitorRows(
                in: database,
                coverage: coverage,
                limit: boundedLimit,
                offset: max(0, offset)
            )
        }
    }

    public func monitorSnapshot(maximum: Int = 50_000) throws -> HistoryMonitorSnapshot {
        let boundedMaximum = min(max(1, maximum), 50_000)
        return try database.read { database in
            let coverage = try HistoryCoverageStore.snapshot(in: database)
            let rows = try HistoryRepositoryStorage.monitorRows(
                in: database,
                coverage: coverage,
                limit: boundedMaximum + 1,
                offset: 0
            )
            return HistoryMonitorSnapshot(
                rows: Array(rows.prefix(boundedMaximum)),
                isComplete: rows.count <= boundedMaximum,
                coverage: coverage
            )
        }
    }

    public func decisionBuckets(
        from start: Date,
        to end: Date,
        width: TimeInterval,
        anchor: Date? = nil
    ) throws -> DecisionBucketSnapshot {
        guard end > start, width.isFinite, width >= 60,
              anchor.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            return DecisionBucketSnapshot(buckets: [], coverage: .gap)
        }
        return try database.read { database in
            let coverage = try HistoryCoverageStore.snapshot(in: database)
                .coverage(from: start, to: end)
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT decision_event FROM flow_lifecycle
                    WHERE decision_at >= ? AND decision_at < ? AND decision_event IS NOT NULL
                    ORDER BY decision_at
                    """,
                arguments: [start.timeIntervalSince1970, end.timeIntervalSince1970]
            )
            let decoder = CanonicalPolicyJSON.decoder()
            var values: [Date: (allow: Int, deny: Int, unresolved: Int)] = [:]
            for row in rows {
                let encoded: Data = row["decision_event"]
                let event = try decoder.decode(RuntimeEvent.self, from: encoded)
                guard let key = DecisionBucketGrid.bucketStart(
                    for: event.occurredAt,
                    anchor: anchor,
                    width: width
                ) else { continue }
                var value = values[key] ?? (0, 0, 0)
                if event.reason != .concreteDecision { value.unresolved += 1 }
                else if event.action == .deny { value.deny += 1 }
                else { value.allow += 1 }
                values[key] = value
            }
            let buckets = values.map { key, value in
                DecisionBucket(
                    start: key,
                    allowed: value.allow,
                    denied: value.deny,
                    unresolved: value.unresolved
                )
            }.sorted { $0.start < $1.start }
            return DecisionBucketSnapshot(buckets: buckets, coverage: coverage)
        }
    }

    public func clearHistory(now: Date = Date()) throws {
        try database.write { database in
            let enabled = try Bool.fetchOne(
                database,
                sql: "SELECT enabled FROM history_settings WHERE singleton_id = 1"
            ) ?? false
            try database.execute(sql: "DELETE FROM flow_events")
            try database.execute(sql: "DELETE FROM flow_lifecycle")
            try HistoryCoverageStore.reset(in: database, enabled: enabled, now: now)
        }
    }

    public func markOpenFlowsAbandoned() throws {
        try database.write { database in
            try database.execute(
                sql: """
                    UPDATE flow_lifecycle SET flow_end_reason = ?
                    WHERE decision_event IS NOT NULL AND closed_at IS NULL
                      AND flow_end_reason IS NULL
                    """,
                arguments: [RuntimeFlowEndReason.appRestartAbandoned.rawValue]
            )
        }
    }

    public func diagnosticCounts() throws -> HistoryDiagnosticCounts {
        try database.read { database in
            HistoryDiagnosticCounts(
                visibleFlows: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM flow_lifecycle WHERE decision_event IS NOT NULL"
                ) ?? 0,
                coverageGaps: try Int.fetchOne(
                    database,
                    sql: "SELECT COUNT(*) FROM coverage_gaps"
                ) ?? 0
            )
        }
    }

    public func exportData(
        format: HistoryExportFormat,
        now: Date,
        maximumBytes: Int = HistoryExportCodec.maximumBytes
    ) async throws -> Data {
        let current = try settings()
        try Task.checkCancellation()
        let snapshot = try monitorSnapshot(maximum: current.maximumFlows)
        return try HistoryExportCodec.encode(
            rows: snapshot.rows,
            format: format,
            exportedAt: now,
            maximumBytes: maximumBytes
        )
    }

    private func persist(
        batches: [(RuntimeEventBatch, UUID?)],
        coverageInterval: HistoryCoverageInterval?,
        now: Date
    ) throws {
        let current = try settings()
        guard current.enabled else { return }
        let encoder = CanonicalPolicyJSON.encoder()
        try database.write { database in
            for (batch, runtimeInstanceID) in batches {
                try HistoryRepositoryStorage.persist(
                    batch,
                    runtimeInstanceID: runtimeInstanceID,
                    in: database,
                    encoder: encoder,
                    now: now
                )
            }
            if let coverageInterval {
                try HistoryCoverageStore.record(coverageInterval, in: database)
            }
            try HistoryRepositoryStorage.enforceRetention(
                in: database,
                settings: current,
                now: now
            )
        }
    }
}
