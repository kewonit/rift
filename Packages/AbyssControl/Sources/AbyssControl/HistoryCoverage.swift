import AbyssIPC
import Foundation
import GRDB

public enum HistoryCoverageGapReason: String, Sendable, Hashable, Codable {
    case extensionRingOverflow
    case extensionRuntimeRestart
    case appWriteFailure
    case historyDisabled
    case legacyUnknown
}

public struct HistoryCoverageInterval: Sendable, Hashable, Codable {
    public let startedAt: Date
    public let endedAt: Date
    public let reason: HistoryCoverageGapReason
    public let droppedCount: UInt64

    public init(
        startedAt: Date,
        endedAt: Date,
        reason: HistoryCoverageGapReason,
        droppedCount: UInt64 = 0
    ) {
        self.startedAt = min(startedAt, endedAt)
        self.endedAt = max(startedAt, endedAt)
        self.reason = reason
        self.droppedCount = droppedCount
    }

    fileprivate func intersects(start: Date, end: Date) -> Bool {
        startedAt < end && endedAt >= start
    }
}

public struct HistoryCoverageSnapshot: Sendable, Hashable {
    public static let maximumIntervals = 1_000
    public static let unavailable = HistoryCoverageSnapshot(
        recordingSince: nil,
        isRecording: false,
        intervals: []
    )

    public let recordingSince: Date?
    public let isRecording: Bool
    public let intervals: [HistoryCoverageInterval]
    public let intervalsWereTruncated: Bool

    public init(
        recordingSince: Date?,
        isRecording: Bool,
        intervals: [HistoryCoverageInterval],
        intervalsWereTruncated: Bool = false
    ) {
        self.recordingSince = recordingSince
        self.isRecording = isRecording
        self.intervals = Array(intervals.prefix(Self.maximumIntervals))
        self.intervalsWereTruncated = intervalsWereTruncated
            || intervals.count > Self.maximumIntervals
    }

    public func coverage(from start: Date, to end: Date) -> HistoryCoverage {
        guard start.timeIntervalSinceReferenceDate.isFinite,
              end.timeIntervalSinceReferenceDate.isFinite,
              end > start,
              isRecording,
              let recordingSince,
              recordingSince.timeIntervalSinceReferenceDate.isFinite else { return .gap }
        let hasUnknownTime = start < recordingSince
            || intervalsWereTruncated
            || intervals.contains { $0.intersects(start: start, end: end) }
        return hasUnknownTime ? .partial : .complete
    }

    public func coverage(for time: MonitorTimeFilter, now: Date) -> HistoryCoverage {
        guard let window = time.window(now: now) else { return .gap }
        return coverage(for: window, now: now)
    }

    public func coverage(for window: MonitorTimeWindow, now: Date) -> HistoryCoverage {
        let start = window.start ?? recordingSince ?? .distantPast
        let end = window.end ?? MonitorTimeWindow.exclusiveEnd(after: now)
        return coverage(from: start, to: end)
    }

    public func adding(_ interval: HistoryCoverageInterval) -> HistoryCoverageSnapshot {
        HistoryCoverageSnapshot(
            recordingSince: recordingSince,
            isRecording: isRecording,
            intervals: intervals + [interval],
            intervalsWereTruncated: intervalsWereTruncated
        )
    }
}

extension HistoryCoverage {
    public static func combined(
        _ lhs: HistoryCoverage,
        _ rhs: HistoryCoverage
    ) -> HistoryCoverage {
        if lhs == .gap || rhs == .gap { return .gap }
        if lhs == .partial || rhs == .partial { return .partial }
        return .complete
    }
}

struct HistoryCoverageIndex {
    private let recordingSince: Date?
    private let isRecording: Bool
    private let intervalsWereTruncated: Bool
    private let ranges: [(start: Date, end: Date)]

    init(_ snapshot: HistoryCoverageSnapshot) {
        recordingSince = snapshot.recordingSince
        isRecording = snapshot.isRecording
        intervalsWereTruncated = snapshot.intervalsWereTruncated
        let sorted = snapshot.intervals.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.endedAt < $1.endedAt
        }
        var merged: [(start: Date, end: Date)] = []
        for interval in sorted {
            if let last = merged.last, interval.startedAt <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.endedAt)
            } else {
                merged.append((interval.startedAt, interval.endedAt))
            }
        }
        ranges = merged
    }

    func coverage(from start: Date, to end: Date) -> HistoryCoverage {
        guard end > start, isRecording, let recordingSince else { return .gap }
        if start < recordingSince || intervalsWereTruncated { return .partial }
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ranges[middle].end < start { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower < ranges.count else { return .complete }
        return ranges[lower].start < end ? .partial : .complete
    }
}

enum HistoryCoverageStore {
    static func snapshot(in database: Database) throws -> HistoryCoverageSnapshot {
        let state = try Row.fetchOne(
            database,
            sql: "SELECT recording_since FROM history_coverage_state WHERE singleton_id = 1"
        )
        let enabled = try Bool.fetchOne(
            database,
            sql: "SELECT enabled FROM history_settings WHERE singleton_id = 1"
        ) ?? false
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT observed_at, started_at, ended_at, reason, reason_code, dropped_count
                FROM coverage_gaps
                ORDER BY COALESCE(started_at, observed_at), id
                LIMIT ?
                """,
            arguments: [HistoryCoverageSnapshot.maximumIntervals + 1]
        )
        let intervals = rows.prefix(HistoryCoverageSnapshot.maximumIntervals).map { row in
            let observed: Double = row["observed_at"]
            let started: Double = row["started_at"] ?? observed
            let ended: Double = row["ended_at"] ?? observed
            let reasonCode: String? = row["reason_code"]
            let legacyReason: String = row["reason"]
            let reason = reasonCode.flatMap(HistoryCoverageGapReason.init(rawValue:))
                ?? (legacyReason.hasPrefix("extensionRingOverflow")
                    ? .extensionRingOverflow : .legacyUnknown)
            let storedCount: Int64 = row["dropped_count"]
            return HistoryCoverageInterval(
                startedAt: started.isFinite
                    ? Date(timeIntervalSince1970: started) : .distantPast,
                endedAt: ended.isFinite
                    ? Date(timeIntervalSince1970: ended) : .distantFuture,
                reason: reason,
                droppedCount: UInt64(bitPattern: storedCount)
            )
        }
        let recordingSeconds: Double? = state?["recording_since"]
        return HistoryCoverageSnapshot(
            recordingSince: recordingSeconds.flatMap {
                $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
            },
            isRecording: enabled,
            intervals: intervals,
            intervalsWereTruncated: rows.count > HistoryCoverageSnapshot.maximumIntervals
        )
    }

    static func noteRecordedEvents(_ events: [RuntimeEvent], in database: Database) throws {
        guard let earliest = events.map(\.occurredAt).min() else { return }
        try database.execute(
            sql: """
                UPDATE history_coverage_state
                SET recording_since = MIN(COALESCE(recording_since, ?), ?)
                WHERE singleton_id = 1
                """,
            arguments: [earliest.timeIntervalSince1970, earliest.timeIntervalSince1970]
        )
    }

    static func markDisabled(in database: Database, now: Date) throws {
        try database.execute(
            sql: """
                UPDATE history_coverage_state
                SET disabled_since = COALESCE(disabled_since, ?)
                WHERE singleton_id = 1
                """,
            arguments: [now.timeIntervalSince1970]
        )
    }

    static func markEnabled(in database: Database, now: Date) throws {
        let disabledSeconds = try Double.fetchOne(
            database,
            sql: "SELECT disabled_since FROM history_coverage_state WHERE singleton_id = 1"
        )
        if let disabledSeconds {
            try record(
                HistoryCoverageInterval(
                    startedAt: Date(timeIntervalSince1970: disabledSeconds),
                    endedAt: now,
                    reason: .historyDisabled
                ),
                in: database
            )
        }
        try database.execute(
            sql: "UPDATE history_coverage_state SET disabled_since = NULL WHERE singleton_id = 1"
        )
    }

    static func reset(in database: Database, enabled: Bool, now: Date) throws {
        try database.execute(sql: "DELETE FROM coverage_gaps")
        try database.execute(
            sql: """
                UPDATE history_coverage_state
                SET recording_since = ?, disabled_since = ?
                WHERE singleton_id = 1
                """,
            arguments: [now.timeIntervalSince1970, enabled ? nil : now.timeIntervalSince1970]
        )
    }

    static func advanceBaseline(to date: Date, in database: Database) throws {
        try database.execute(
            sql: """
                UPDATE history_coverage_state
                SET recording_since = MAX(COALESCE(recording_since, ?), ?)
                WHERE singleton_id = 1
                """,
            arguments: [date.timeIntervalSince1970, date.timeIntervalSince1970]
        )
    }

    static func record(_ interval: HistoryCoverageInterval, in database: Database) throws {
        let sourceID = String(format: "%016llx-%016llx",
            interval.startedAt.timeIntervalSince1970.bitPattern,
            interval.endedAt.timeIntervalSince1970.bitPattern)
        try database.execute(
            sql: """
                DELETE FROM coverage_gaps
                WHERE reason_code = ? AND source_id = ?
                  AND started_at = ? AND ended_at = ?
                """,
            arguments: [interval.reason.rawValue, sourceID,
                        interval.startedAt.timeIntervalSince1970,
                        interval.endedAt.timeIntervalSince1970]
        )
        try insert(interval, providerEpoch: nil, sourceID: sourceID, in: database)
    }

    static func recordDroppedHighWater(
        _ batch: RuntimeEventBatch,
        runtimeInstanceID: UUID?,
        in database: Database,
        now: Date
    ) throws {
        guard batch.droppedCount > 0 else { return }
        let sourceID = runtimeInstanceID?.uuidString.lowercased() ?? "legacy"
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT provider_epoch, observed_at, started_at, ended_at, dropped_count
                FROM coverage_gaps
                WHERE reason_code = ? AND COALESCE(source_id, 'legacy') = ?
                ORDER BY id
                """,
            arguments: [HistoryCoverageGapReason.extensionRingOverflow.rawValue, sourceID]
        )
        var highWater: UInt64 = 0
        var startedAt = batch.events.map(\.occurredAt).min() ?? now
        var endedAt = now
        var providerEpoch = batch.providerEpoch?.uuidString.lowercased()
        for row in rows {
            let stored: Int64 = row["dropped_count"]
            let observed: Double = row["observed_at"]
            let storedStart: Double = row["started_at"] ?? observed
            let storedEnd: Double = row["ended_at"] ?? observed
            highWater = max(highWater, UInt64(bitPattern: stored))
            startedAt = min(startedAt, Date(timeIntervalSince1970: storedStart))
            endedAt = max(endedAt, Date(timeIntervalSince1970: storedEnd))
            if UInt64(bitPattern: stored) == highWater {
                providerEpoch = row["provider_epoch"] ?? providerEpoch
            }
        }
        guard batch.droppedCount > highWater else { return }
        providerEpoch = batch.providerEpoch?.uuidString.lowercased() ?? providerEpoch
        try database.execute(
            sql: "DELETE FROM coverage_gaps WHERE reason_code = ? AND COALESCE(source_id, 'legacy') = ?",
            arguments: [HistoryCoverageGapReason.extensionRingOverflow.rawValue, sourceID]
        )
        try insert(
            HistoryCoverageInterval(
                startedAt: startedAt,
                endedAt: endedAt,
                reason: .extensionRingOverflow,
                droppedCount: batch.droppedCount
            ),
            providerEpoch: providerEpoch,
            sourceID: sourceID,
            in: database
        )
    }

    static func enforceRetention(in database: Database, cutoff: Date) throws {
        try database.execute(
            sql: """
                UPDATE history_coverage_state
                SET recording_since = MAX(COALESCE(recording_since, ?), ?)
                WHERE singleton_id = 1
                """,
            arguments: [cutoff.timeIntervalSince1970, cutoff.timeIntervalSince1970]
        )
        try database.execute(
            sql: "DELETE FROM coverage_gaps WHERE COALESCE(ended_at, observed_at) < ?",
            arguments: [cutoff.timeIntervalSince1970]
        )
        let discardedThrough = try Double.fetchOne(
            database,
            sql: """
                SELECT MAX(COALESCE(ended_at, observed_at)) FROM coverage_gaps
                WHERE id NOT IN (
                    SELECT id FROM coverage_gaps
                    ORDER BY COALESCE(ended_at, observed_at) DESC, id DESC LIMIT 1000
                )
                """
        )
        if let discardedThrough {
            try database.execute(
                sql: """
                    UPDATE history_coverage_state
                    SET recording_since = MAX(COALESCE(recording_since, ?), ?)
                    WHERE singleton_id = 1
                    """,
                arguments: [discardedThrough, discardedThrough]
            )
        }
        try database.execute(sql: """
            DELETE FROM coverage_gaps WHERE id NOT IN (
                SELECT id FROM coverage_gaps
                ORDER BY COALESCE(ended_at, observed_at) DESC, id DESC LIMIT 1000
            )
            """)
    }

    private static func insert(
        _ interval: HistoryCoverageInterval,
        providerEpoch: String?,
        sourceID: String,
        in database: Database
    ) throws {
        let legacyReason = "\(interval.reason.rawValue):\(sourceID)"
        try database.execute(
            sql: """
                INSERT INTO coverage_gaps
                    (provider_epoch, observed_at, reason, dropped_count,
                     started_at, ended_at, reason_code, source_id)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [providerEpoch, interval.endedAt.timeIntervalSince1970, legacyReason,
                        Int64(bitPattern: interval.droppedCount),
                        interval.startedAt.timeIntervalSince1970,
                        interval.endedAt.timeIntervalSince1970,
                        interval.reason.rawValue, sourceID]
        )
    }
}
