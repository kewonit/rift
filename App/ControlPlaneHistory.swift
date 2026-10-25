import RiftControl
import RiftIPC
import Foundation

struct MonitorRowsSnapshot: Sendable {
    let rows: [MonitorEventRow]
    let isComplete: Bool
    let coverage: HistoryCoverageSnapshot
    var cursor: HistoryChangeCursor? = nil
    var window: MonitorTimeWindow? = nil

    var persistedSnapshot: HistoryMonitorSnapshot {
        HistoryMonitorSnapshot(rows: rows, isComplete: isComplete, coverage: coverage, cursor: cursor)
    }
}

extension ControlPlaneController {
    func monitorDidAppear(menu: Bool = false) {
        if menu { visibleMenuCount += 1 }
        else { visibleMonitorCount += 1 }
        monitorIsVisible = true
        setVisualActivityVisible(true)
        requestActivitySubscriptionUpdate()
    }

    func monitorDidDisappear(menu: Bool = false) {
        if menu { visibleMenuCount = max(0, visibleMenuCount - 1) }
        else { visibleMonitorCount = max(0, visibleMonitorCount - 1) }
        monitorIsVisible = visibleMonitorCount + visibleMenuCount > 0
        if !monitorIsVisible {
            if isMinimalActivity { transientHistory = TransientHistoryBuffer(maximumFlows: Self.minimalFlowLimit); clearRecentActivity() }
            else { transientHistory.clearDisplay() }
            setVisualActivityVisible(false)
        }
        requestActivitySubscriptionUpdate()
    }

    func retainAndPersist(
        _ batch: RuntimeEventBatch,
        runtimeInstanceID: UUID?
    ) async {
        guard persistentHistoryEnabled, !batch.events.isEmpty || batch.droppedCount > 0 else { return }
        do {
            if let history {
                let now = Date()
                let replay = transientHistory.replaySnapshot()
                if let failureInterval = replay.failureInterval {
                    try await history.ingestRecovering(
                        replayBatches: replay.batches,
                        currentBatch: batch,
                        writeFailureInterval: failureInterval,
                        now: now,
                        runtimeInstanceID: runtimeInstanceID
                    )
                } else {
                    try await history.ingest(
                        batch,
                        now: now,
                        runtimeInstanceID: runtimeInstanceID
                    )
                }
                transientHistory.clear()
            } else {
                transientHistory.retainForReplay(batch)
                recordStartupIssue("Rift can’t save activity right now. Recent activity is kept in memory for now.")
            }
        } catch {
            transientHistory.retainForReplay(batch)
            recordStartupIssue("Rift can’t save activity right now. Recent activity is kept in memory for now.")
        }
        do {
            try await repository?.recordUsage(batch)
        } catch {
            recordStartupIssue("Rule usage counts may be incomplete because Rift couldn’t save them.")
        }
    }

    func monitorRowsSnapshot(
        maximum: Int = 50_000,
        window: MonitorTimeWindow? = nil,
        previous: MonitorRowsSnapshot? = nil
    ) async throws -> MonitorRowsSnapshot {
        let boundedMaximum = min(max(1, maximum), 50_000)
#if DEBUG
        if isUIFixture {
            return MonitorRowsSnapshot(
                rows: Array(MonitorFixtureData.rows.prefix(boundedMaximum)),
                isComplete: MonitorFixtureData.rows.count <= boundedMaximum,
                coverage: HistoryCoverageSnapshot(
                    recordingSince: .distantPast,
                    isRecording: true,
                    intervals: []
                )
            )
        }
#endif
        if isMinimalActivity {
            return MonitorRowsSnapshot(
                rows: Array(recentActivityRows.prefix(boundedMaximum)),
                isComplete: false, coverage: .unavailable
            )
        }
        let transient = transientHistory.page(limit: TransientHistoryBuffer.maximumFlows)
        let persistedMaximum = min(50_000, boundedMaximum + transient.count)
        let persisted: HistoryMonitorSnapshot
        let windowCanAdvance = previous.map { old in
            guard old.window?.end == window?.end else { return false }
            guard let oldStart = old.window?.start else { return true }
            return window?.start.map { $0 >= oldStart } ?? false
        } ?? false
        if transient.isEmpty, windowCanAdvance, let history, let previous, let cursor = previous.cursor {
            let delta = try await history.monitorChanges(after: cursor)
            if !delta.requiresFullRefresh,
               previous.isComplete || (delta.updatedRows.isEmpty && delta.removedFlowKeys.isEmpty) {
                persisted = try await MonitorHistoryMerge.applying(
                    delta, to: previous.persistedSnapshot, window: window, maximum: persistedMaximum
                )
            } else {
                persisted = try await history.monitorSnapshot(maximum: persistedMaximum, window: window)
            }
        } else {
            persisted = try await history?.monitorSnapshot(maximum: persistedMaximum, window: window)
                ?? HistoryMonitorSnapshot(rows: [], isComplete: true, coverage: .unavailable)
        }
        if transient.isEmpty {
            return MonitorRowsSnapshot(
                rows: persisted.rows, isComplete: persisted.isComplete,
                coverage: persisted.coverage, cursor: persisted.cursor, window: window
            )
        }
        var rowsByID = Dictionary(uniqueKeysWithValues: persisted.rows.map { ($0.id, $0) })
        for row in transient { rowsByID[row.id] = row }
        let rows = rowsByID.values.filter { window?.contains($0.event.occurredAt) ?? true }.sorted {
            if $0.event.occurredAt != $1.event.occurredAt {
                return $0.event.occurredAt > $1.event.occurredAt
            }
            return $0.id > $1.id
        }
        let coverage = transientHistory.pendingReplayInterval.map { persisted.coverage.adding($0) }
            ?? persisted.coverage
        return MonitorRowsSnapshot(
            rows: Array(rows.prefix(boundedMaximum)),
            isComplete: persisted.isComplete && rows.count <= boundedMaximum,
            coverage: coverage, window: window
        )
    }

    func monitorPage(limit: Int = 500, offset: Int = 0) async throws -> [MonitorEventRow] {
        let boundedLimit = min(max(1, limit), 1_000)
        guard offset >= 0, offset < 50_000 else { return [] }
        let requiredCount = min(50_000, offset + boundedLimit)
        let snapshot = try await monitorRowsSnapshot(maximum: requiredCount)
        let rows = snapshot.rows
        let start = min(offset, rows.count)
        let end = min(rows.count, start + boundedLimit)
        return Array(rows[start..<end])
    }

    func decisionBuckets(
        from start: Date,
        to end: Date,
        width: TimeInterval,
        anchor: Date? = nil
    ) async throws -> DecisionBucketSnapshot {
        guard end > start, width.isFinite, width >= 60,
              anchor.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else {
            return DecisionBucketSnapshot(buckets: [], coverage: .gap)
        }
#if DEBUG
        if isUIFixture {
            return DecisionBucketSnapshot(
                buckets: MonitorFixtureData.decisionBuckets(
                    from: start, to: end, width: width, anchor: anchor
                ),
                coverage: .complete
            )
        }
#endif
        if isMinimalActivity {
            var values: [Date: (allowed: Int, denied: Int, unresolved: Int)] = [:]
            for row in recentActivityRows where row.event.occurredAt >= start && row.event.occurredAt < end {
                guard let key = DecisionBucketGrid.bucketStart(
                    for: row.event.occurredAt, anchor: anchor, width: width
                ) else { continue }
                var value = values[key] ?? (0, 0, 0)
                if row.event.reason != .concreteDecision { value.unresolved += 1 }
                else if row.event.action == .deny { value.denied += 1 }
                else { value.allowed += 1 }
                values[key] = value
            }
            return DecisionBucketSnapshot(
                buckets: values.map { DecisionBucket(start: $0.key, allowed: $0.value.allowed,
                                                     denied: $0.value.denied, unresolved: $0.value.unresolved) }
                    .sorted { $0.start < $1.start }, coverage: .partial
            )
        }
        let persisted = try await history?.decisionBuckets(
            from: start, to: end, width: width, anchor: anchor
        )
            ?? DecisionBucketSnapshot(buckets: [], coverage: .gap)
        var values = Dictionary(uniqueKeysWithValues: persisted.buckets.map { ($0.start, $0) })
        var includesTransient = false
        for row in transientHistory.page(limit: TransientHistoryBuffer.maximumFlows) {
            let event = row.event
            guard event.occurredAt >= start, event.occurredAt < end else { continue }
            includesTransient = true
            guard let bucketStart = DecisionBucketGrid.bucketStart(
                for: event.occurredAt,
                anchor: anchor,
                width: width
            ) else { continue }
            let current = values[bucketStart]
                ?? DecisionBucket(start: bucketStart, allowed: 0, denied: 0, unresolved: 0)
            let unresolved = event.reason != .concreteDecision
            values[bucketStart] = DecisionBucket(
                start: bucketStart,
                allowed: current.allowed + (unresolved || event.action == .deny ? 0 : 1),
                denied: current.denied + (!unresolved && event.action == .deny ? 1 : 0),
                unresolved: current.unresolved + (unresolved ? 1 : 0)
            )
        }
        let pendingIntersects = transientHistory.pendingReplayInterval.map {
            $0.startedAt < end && $0.endedAt >= start
        } ?? false
        let coverage = includesTransient || pendingIntersects
            ? HistoryCoverage.combined(persisted.coverage, .partial)
            : persisted.coverage
        return DecisionBucketSnapshot(
            buckets: values.values.sorted { $0.start < $1.start },
            coverage: coverage
        )
    }

    private func openHistoryForExplicitRequest() async throws -> HistoryRepository? {
        if let history { return history }
        guard let historyDatabaseURL else { return nil }
        let isNew = !FileManager.default.fileExists(atPath: historyDatabaseURL.path)
        let opened = try HistoryDatabase.openRecovering(at: historyDatabaseURL)
        let repository = HistoryRepository(database: opened.database)
        if isNew { try await repository.configure(enabled: persistentHistoryEnabled, retentionDays: 30, maximumFlows: 50_000) }
        history = repository
        recordHistoryRecovery(opened.recovery)
        return repository
    }

    func historySettings() async throws -> HistorySettings? {
        try await openHistoryForExplicitRequest()?.settings()
    }

    func configureHistory(enabled: Bool, retentionDays: Int, maximumFlows: Int) async throws {
        let history = try await openHistoryForExplicitRequest()
        try await history?.configure(
            enabled: enabled, retentionDays: retentionDays, maximumFlows: maximumFlows
        )
        persistentHistoryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "persistentHistoryEnabled")
        if enabled { transientHistory = TransientHistoryBuffer(); clearRecentActivity() }
        else {
            transientHistory = TransientHistoryBuffer(maximumFlows: Self.minimalFlowLimit)
            try await repository?.markUsageGap()
        }
        requestActivitySubscriptionUpdate()
        recordRuntimeActivity(true)
    }

    func clearHistory(clearUsage: Bool = false) async throws {
        try await openHistoryForExplicitRequest()?.clearHistory()
        if clearUsage { try await repository?.clearUsage() }
        transientHistory.clear()
        clearRecentActivity()
        recordRuntimeActivity(true)
    }

    func historyExportData(format: HistoryExportFormat) async throws -> Data {
        guard let history = try await openHistoryForExplicitRequest() else { throw RuleCommandError.missingConfiguration }
        return try await history.exportData(format: format, now: Date())
    }
}
