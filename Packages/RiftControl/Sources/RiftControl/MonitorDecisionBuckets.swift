import Foundation

public enum MonitorDecisionBuckets {
    /// The rows the chart should count. They follow the same search and filters
    /// as everything else, but not a dragged selection, which would shrink the
    /// chart to the part someone just picked.
    public static func rows(
        displayed: [MonitorEventRow],
        all rows: [MonitorEventRow],
        query: MonitorQueryState,
        now: Date,
        context: MonitorSearchContext = .none
    ) -> [MonitorEventRow] {
        guard query.selectedTimeRange != nil else { return displayed }
        var whole = query
        whole.selectedTimeRange = nil
        return whole.apply(to: rows, now: now, context: context).map(\.source)
    }

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
            switch row.event.tally {
            case .allowed: value.allow += 1
            case .blocked: value.deny += 1
            case .noRule: value.unresolved += 1
            }
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
