import RiftCore
import RiftIPC
import Foundation
import GRDB

/// How often each rule decided a connection, and how much of that Rift saw.
extension PolicyRepository {
    public func recordUsage(_ batch: RuntimeEventBatch) throws {
        try database.write { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT state, provider_epoch FROM usage_coverage WHERE singleton_id = 1"
            )
            let priorState = (row?["state"] as String?).flatMap(HistoryCoverage.init(rawValue:))
                ?? .gap
            let priorEpoch: String? = row?["provider_epoch"]
            let nextEpoch = batch.providerEpoch?.uuidString.lowercased()
            let epochChanged = priorEpoch != nil && nextEpoch != nil && priorEpoch != nextEpoch
            let coverage: HistoryCoverage
            if priorState == .gap {
                coverage = .gap
            } else if epochChanged || batch.droppedCount > 0 {
                coverage = .partial
            } else {
                coverage = priorState
            }
            try database.execute(
                sql: "UPDATE usage_coverage SET state = ?, provider_epoch = COALESCE(?, provider_epoch) WHERE singleton_id = 1",
                arguments: [coverage.rawValue, nextEpoch]
            )
            for event in batch.events where event.kind == .decision {
                var affected = Set(event.affectingRuleIDs)
                if let winner = event.winningRuleID { affected.insert(winner) }
                for id in affected {
                    let value = id.uuidString.lowercased()
                    try database.execute(
                        sql: """
                            INSERT INTO rule_usage (rule_id, lower_bound_count, last_used_at)
                            SELECT ?, 1, ? WHERE EXISTS (SELECT 1 FROM rules WHERE id = ?)
                            ON CONFLICT(rule_id) DO UPDATE SET
                                lower_bound_count = CASE
                                    WHEN rule_usage.lower_bound_count < 9223372036854775807
                                    THEN rule_usage.lower_bound_count + 1
                                    ELSE rule_usage.lower_bound_count
                                END,
                                last_used_at = MAX(rule_usage.last_used_at, excluded.last_used_at)
                            """,
                        arguments: [value, event.occurredAt.timeIntervalSince1970, value]
                    )
                }
            }
        }
    }

    public func markUsagePartial() throws {
        try database.write {
            try $0.execute(
                sql: "UPDATE usage_coverage SET state = 'partial' WHERE singleton_id = 1 AND state = 'complete'"
            )
        }
    }

    public func markUsageGap() throws {
        try database.write { database in
            try database.execute(
                sql: "UPDATE usage_coverage SET state = ? WHERE singleton_id = 1",
                arguments: [HistoryCoverage.gap.rawValue]
            )
        }
    }

    public func clearUsage() throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM rule_usage")
            try database.execute(
                sql: "UPDATE usage_coverage SET state = ?, provider_epoch = NULL WHERE singleton_id = 1",
                arguments: [HistoryCoverage.gap.rawValue]
            )
        }
    }

    public func ruleUsage(ruleIDs: Set<UUID>) throws -> [UUID: RuleUsageValue] {
        guard !ruleIDs.isEmpty else { return [:] }
        return try database.read { database in
            let stateValue = try String.fetchOne(
                database,
                sql: "SELECT state FROM usage_coverage WHERE singleton_id = 1"
            )
            let coverage = stateValue.flatMap(HistoryCoverage.init(rawValue:)) ?? .gap
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT rule_id, lower_bound_count, last_used_at FROM rule_usage"
            )
            var stored: [UUID: (Int, Date?)] = [:]
            for row in rows {
                let value: String = row["rule_id"]
                guard let id = UUID(uuidString: value), ruleIDs.contains(id) else { continue }
                let count: Int64 = row["lower_bound_count"]
                let date: Double? = row["last_used_at"]
                stored[id] = (Int(clamping: count), date.map(Date.init(timeIntervalSince1970:)))
            }
            return Dictionary(uniqueKeysWithValues: ruleIDs.map { id in
                let value = stored[id] ?? (0, nil)
                return (id, RuleUsageValue(
                    lowerBoundCount: value.0, lastUsedAt: value.1, coverage: coverage
                ))
            })
        }
    }
}
