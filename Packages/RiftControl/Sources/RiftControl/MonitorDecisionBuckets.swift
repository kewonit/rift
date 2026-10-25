import Foundation

public enum MonitorDecisionBuckets {
    public static func build(
        rows: [MonitorEventRow],
        query: MonitorQueryState,
        now: Date,
        coverage: HistoryCoverageSnapshot,
        isComplete: Bool
    ) -> DecisionBucketSnapshot {
        guard let window = query.baseTimeWindow(now: now) else {
            return DecisionBucketSnapshot(buckets: [], coverage: .gap)
        }
        var values: [Date: (allow: Int, deny: Int, unresolved: Int)] = [:]
        for row in rows where window.contains(row.event.occurredAt) {
            guard let key = DecisionBucketGrid.bucketStart(
                for: row.event.occurredAt, anchor: window.start, width: query.time.decisionBucketWidth
            ) else { continue }
            var value = values[key] ?? (0, 0, 0)
            if row.event.reason != .concreteDecision { value.unresolved += 1 }
            else if row.event.action == .deny { value.deny += 1 }
            else { value.allow += 1 }
            values[key] = value
        }
        return DecisionBucketSnapshot(
            buckets: values.map { key, value in
                DecisionBucket(start: key, allowed: value.allow, denied: value.deny, unresolved: value.unresolved)
            }.sorted { $0.start < $1.start },
            coverage: .combined(coverage.coverage(for: window, now: now), isComplete ? .complete : .partial)
        )
    }
}
