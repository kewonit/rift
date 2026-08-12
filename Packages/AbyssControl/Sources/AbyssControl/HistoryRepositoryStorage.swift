import AbyssCore
import AbyssIPC
import Foundation
import GRDB

enum HistoryRepositoryStorage {
    static func persist(
        _ batch: RuntimeEventBatch,
        runtimeInstanceID: UUID?,
        in database: Database,
        encoder: JSONEncoder,
        now: Date
    ) throws {
        let events = Array(batch.events.prefix(IPCProtocolLimits.maximumEventBatchCount))
        var recordedEvents: [RuntimeEvent] = []
        for event in events {
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO flow_events
                        (provider_epoch, sequence, occurred_at, flow_id, encoded_event, event_kind)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event.providerEpoch.uuidString.lowercased(), Int64(bitPattern: event.sequence),
                    event.occurredAt.timeIntervalSince1970,
                    event.flow.flowID.uuidString.lowercased(), try encoder.encode(event),
                    event.kind.rawValue,
                ]
            )
            if database.changesCount > 0 {
                try updateLifecycle(event, in: database, encoder: encoder)
                recordedEvents.append(event)
            }
        }
        try HistoryCoverageStore.noteRecordedEvents(recordedEvents, in: database)
        try HistoryCoverageStore.recordDroppedHighWater(
            batch,
            runtimeInstanceID: runtimeInstanceID,
            in: database,
            now: now
        )
    }

    static func monitorRows(
        in database: Database,
        coverage: HistoryCoverageSnapshot,
        limit: Int,
        offset: Int
    ) throws -> [MonitorEventRow] {
        let rows = try Row.fetchAll(
            database,
            sql: """
                SELECT decision_event, closed_at, bytes_inbound, bytes_outbound, flow_end_reason
                FROM flow_lifecycle
                WHERE decision_event IS NOT NULL
                ORDER BY decision_at DESC, decision_sequence DESC,
                         provider_epoch DESC, flow_id DESC
                LIMIT ? OFFSET ?
                """,
            arguments: [limit, offset]
        )
        let decoder = CanonicalPolicyJSON.decoder()
        let coverageIndex = HistoryCoverageIndex(coverage)
        return try rows.map { row in
            let encoded: Data = row["decision_event"]
            let event = try decoder.decode(RuntimeEvent.self, from: encoded)
            let closedSeconds: Double? = row["closed_at"]
            let closedAt = closedSeconds.map(Date.init(timeIntervalSince1970:))
            let inbound: Int64? = row["bytes_inbound"]
            let outbound: Int64? = row["bytes_outbound"]
            let endReason: String? = row["flow_end_reason"]
            let intervalEnd = max(closedAt ?? event.occurredAt, event.occurredAt)
                .addingTimeInterval(0.001)
            let rangeCoverage = coverageIndex.coverage(
                from: event.occurredAt,
                to: intervalEnd
            )
            let bytesMayBeLegacyClamped = inbound == Int64.max || outbound == Int64.max
            return MonitorEventRow(
                event: event,
                coverage: bytesMayBeLegacyClamped
                    ? .combined(rangeCoverage, .partial) : rangeCoverage,
                closedAt: closedAt,
                bytesInbound: inbound.map { UInt64(bitPattern: $0) },
                bytesOutbound: outbound.map { UInt64(bitPattern: $0) },
                flowEndReason: endReason.flatMap(RuntimeFlowEndReason.init(rawValue:))
            )
        }
    }

    static func enforceRetention(
        in database: Database,
        settings: HistorySettings,
        now: Date
    ) throws {
        let cutoff = now.addingTimeInterval(TimeInterval(-settings.retentionDays * 86_400))
        try database.execute(
            sql: """
                DELETE FROM flow_lifecycle
                WHERE COALESCE(MAX(decision_at, closed_at), decision_at, closed_at, 0) < ?
                """,
            arguments: [cutoff.timeIntervalSince1970]
        )
        let flowCount = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM flow_lifecycle") ?? 0
        if flowCount > settings.maximumFlows {
            let capacityDiscardedThrough = try Double.fetchOne(
                database,
                sql: """
                    SELECT MAX(COALESCE(MAX(decision_at, closed_at), decision_at, closed_at, 0))
                    FROM flow_lifecycle WHERE rowid IN (
                        SELECT rowid FROM flow_lifecycle
                        ORDER BY CASE
                                     WHEN decision_event IS NOT NULL THEN 2
                                     WHEN closed_at IS NOT NULL THEN 1
                                     ELSE 0
                                 END DESC,
                                 COALESCE(MAX(decision_at, closed_at), decision_at, closed_at, 0) DESC,
                                 COALESCE(decision_sequence, 0) DESC,
                                 provider_epoch DESC, flow_id DESC
                        LIMIT -1 OFFSET ?
                    )
                    """,
                arguments: [settings.maximumFlows]
            )
            try database.execute(
                sql: """
                    DELETE FROM flow_lifecycle WHERE rowid IN (
                        SELECT rowid FROM flow_lifecycle
                        ORDER BY CASE
                                     WHEN decision_event IS NOT NULL THEN 2
                                     WHEN closed_at IS NOT NULL THEN 1
                                     ELSE 0
                                 END DESC,
                                 COALESCE(MAX(decision_at, closed_at), decision_at, closed_at, 0) DESC,
                                 COALESCE(decision_sequence, 0) DESC,
                                 provider_epoch DESC, flow_id DESC
                        LIMIT -1 OFFSET ?
                    )
                """,
                arguments: [settings.maximumFlows]
            )
            if let capacityDiscardedThrough {
                try HistoryCoverageStore.advanceBaseline(
                    to: Date(timeIntervalSince1970: capacityDiscardedThrough),
                    in: database
                )
            }
        }
        try database.execute(sql: """
            DELETE FROM flow_events
            WHERE NOT EXISTS (
                SELECT 1 FROM flow_lifecycle
                WHERE flow_lifecycle.provider_epoch = flow_events.provider_epoch
                  AND flow_lifecycle.flow_id = flow_events.flow_id
            )
            """)
        try HistoryCoverageStore.enforceRetention(in: database, cutoff: cutoff)
    }

    private static func updateLifecycle(
        _ event: RuntimeEvent,
        in database: Database,
        encoder: JSONEncoder
    ) throws {
        let epoch = event.providerEpoch.uuidString.lowercased()
        let flowID = event.flow.flowID.uuidString.lowercased()
        switch event.kind {
        case .decision:
            try database.execute(
                sql: """
                    INSERT INTO flow_lifecycle
                        (provider_epoch, flow_id, decision_sequence, decision_at, decision_event)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(provider_epoch, flow_id) DO UPDATE SET
                        decision_sequence = CASE
                            WHEN flow_lifecycle.decision_event IS NULL
                              OR excluded.decision_sequence < flow_lifecycle.decision_sequence
                            THEN excluded.decision_sequence ELSE flow_lifecycle.decision_sequence
                        END,
                        decision_at = CASE
                            WHEN flow_lifecycle.decision_event IS NULL
                              OR excluded.decision_sequence < flow_lifecycle.decision_sequence
                            THEN excluded.decision_at ELSE flow_lifecycle.decision_at
                        END,
                        decision_event = CASE
                            WHEN flow_lifecycle.decision_event IS NULL
                              OR excluded.decision_sequence < flow_lifecycle.decision_sequence
                            THEN excluded.decision_event ELSE flow_lifecycle.decision_event
                        END
                    """,
                arguments: [
                    epoch, flowID, Int64(bitPattern: event.sequence),
                    event.occurredAt.timeIntervalSince1970, try encoder.encode(event),
                ]
            )
        case .statistics, .closed:
            let inbound = event.bytesInbound.map { Int64(bitPattern: $0) }
            let outbound = event.bytesOutbound.map { Int64(bitPattern: $0) }
            try database.execute(
                sql: """
                    INSERT INTO flow_lifecycle
                        (provider_epoch, flow_id, decision_sequence, decision_at,
                         closed_at, bytes_inbound, bytes_outbound, flow_end_reason)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(provider_epoch, flow_id) DO UPDATE SET
                        decision_sequence = CASE
                            WHEN flow_lifecycle.decision_event IS NULL
                            THEN MAX(COALESCE(flow_lifecycle.decision_sequence, 0), excluded.decision_sequence)
                            ELSE flow_lifecycle.decision_sequence
                        END,
                        decision_at = CASE
                            WHEN flow_lifecycle.decision_event IS NULL
                            THEN MAX(COALESCE(flow_lifecycle.decision_at, excluded.decision_at), excluded.decision_at)
                            ELSE flow_lifecycle.decision_at
                        END,
                        closed_at = COALESCE(excluded.closed_at, flow_lifecycle.closed_at),
                        bytes_inbound = CASE
                            WHEN excluded.bytes_inbound IS NULL THEN flow_lifecycle.bytes_inbound
                            WHEN flow_lifecycle.bytes_inbound IS NULL THEN excluded.bytes_inbound
                            WHEN excluded.bytes_inbound < 0 AND flow_lifecycle.bytes_inbound >= 0
                                THEN excluded.bytes_inbound
                            WHEN excluded.bytes_inbound >= 0 AND flow_lifecycle.bytes_inbound < 0
                                THEN flow_lifecycle.bytes_inbound
                            ELSE MAX(flow_lifecycle.bytes_inbound, excluded.bytes_inbound)
                        END,
                        bytes_outbound = CASE
                            WHEN excluded.bytes_outbound IS NULL THEN flow_lifecycle.bytes_outbound
                            WHEN flow_lifecycle.bytes_outbound IS NULL THEN excluded.bytes_outbound
                            WHEN excluded.bytes_outbound < 0 AND flow_lifecycle.bytes_outbound >= 0
                                THEN excluded.bytes_outbound
                            WHEN excluded.bytes_outbound >= 0 AND flow_lifecycle.bytes_outbound < 0
                                THEN flow_lifecycle.bytes_outbound
                            ELSE MAX(flow_lifecycle.bytes_outbound, excluded.bytes_outbound)
                        END,
                        flow_end_reason = COALESCE(excluded.flow_end_reason, flow_lifecycle.flow_end_reason)
                    """,
                arguments: [
                    epoch, flowID, Int64(bitPattern: event.sequence),
                    event.occurredAt.timeIntervalSince1970,
                    event.kind == .closed ? event.occurredAt.timeIntervalSince1970 : nil,
                    inbound, outbound, event.flowEndReason?.rawValue,
                ]
            )
        }
    }
}
