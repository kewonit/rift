import AbyssControl
import AbyssIPC
import Foundation

struct MonitorRowsSnapshot {
    let rows: [MonitorEventRow]
    let isComplete: Bool
    let coverage: HistoryCoverageSnapshot
}

extension ControlPlaneController {
    func monitorDidAppear() { monitorIsVisible = true }

    func monitorDidDisappear() {
        monitorIsVisible = false
        transientHistory.clearDisplay()
    }

    func retainAndPersist(
        _ batch: RuntimeEventBatch,
        runtimeInstanceID: UUID?
    ) async {
        guard !batch.events.isEmpty || batch.droppedCount > 0 else { return }
        var historyEnabled = false
        do {
            if let history {
                historyEnabled = try await history.settings().enabled
                if historyEnabled {
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
                } else if monitorIsVisible {
                    transientHistory.ingest(batch)
                } else {
                    transientHistory.clearDisplay()
                }
            } else {
                transientHistory.retainForReplay(batch)
                recordStartupIssue("Activity storage is unavailable. Recent activity is being kept temporarily.")
            }
        } catch {
            transientHistory.retainForReplay(batch)
            recordStartupIssue("Activity storage is unavailable. Recent activity is being kept temporarily.")
        }
        guard historyEnabled else { return }
        do {
            try await repository?.recordUsage(batch)
        } catch {
            recordStartupIssue("Rule usage may be incomplete because activity counters could not be saved.")
        }
    }

    func monitorRowsSnapshot(maximum: Int = 50_000) async throws -> MonitorRowsSnapshot {
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
        let transient = transientHistory.page(limit: TransientHistoryBuffer.maximumFlows)
        let persistedMaximum = min(50_000, boundedMaximum + transient.count)
        let persisted = try await history?.monitorSnapshot(maximum: persistedMaximum)
            ?? HistoryMonitorSnapshot(
                rows: [],
                isComplete: true,
                coverage: .unavailable
            )
        var rowsByID = Dictionary(uniqueKeysWithValues: persisted.rows.map { ($0.id, $0) })
        for row in transient { rowsByID[row.id] = row }
        let rows = rowsByID.values.sorted {
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
            coverage: coverage
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

    func historySettings() async throws -> HistorySettings? { try await history?.settings() }

    func configureHistory(enabled: Bool, retentionDays: Int, maximumFlows: Int) async throws {
        try await history?.configure(
            enabled: enabled, retentionDays: retentionDays, maximumFlows: maximumFlows
        )
        if enabled { transientHistory.clearDisplay() }
        else {
            if !monitorIsVisible { transientHistory.clearDisplay() }
            try await repository?.markUsageGap()
        }
    }

    func clearHistory(clearUsage: Bool = false) async throws {
        try await history?.clearHistory()
        if clearUsage { try await repository?.clearUsage() }
        transientHistory.clear()
    }

    func historyExportData(format: HistoryExportFormat) async throws -> Data {
        guard let history else { throw RuleCommandError.missingConfiguration }
        return try await history.exportData(format: format, now: Date())
    }

    func drainRuntimeData() async {
        var successfulRuntimeDrain: (id: UUID, at: Date)?
        for _ in 0..<32 {
            let runtimeInstanceID = lastHandshake?.runtimeInstanceID
            let incoming: [PromptRequest]
            let batch: RuntimeEventBatch
            do {
                incoming = try await client.drainPrompts()
                batch = try await client.drainEvents()
            } catch {
                break
            }
            if let runtimeInstanceID {
                successfulRuntimeDrain = (runtimeInstanceID, Date())
            }
            let notificationEvents = (try? await client.drainNotifications()) ?? []
            mergeIncomingPrompts(incoming, now: Date())
            reconcilePendingPrompts(with: batch)
            let lossChanged = recordRuntimeLoss(batch.droppedCount)
            recordRecentDeny(from: batch.events)
            await notifications.route(batch.events)
            await notifications.route(notificationEvents)
            await retainAndPersist(batch, runtimeInstanceID: runtimeInstanceID)
            recordRuntimeActivity(!batch.events.isEmpty || lossChanged)
            if incoming.isEmpty && batch.events.isEmpty && notificationEvents.isEmpty { break }
        }
        if let successfulRuntimeDrain {
            recordRuntimeActivity(await recordAuthenticatedRuntimeDrain(
                successfulRuntimeDrain.id,
                at: successfulRuntimeDrain.at
            ))
        }
    }

    private func recordAuthenticatedRuntimeDrain(_ runtimeInstanceID: UUID, at date: Date) async -> Bool {
        guard let history else { return false }
        do {
            let transition = try await history.recordAuthenticatedRuntimeDrain(
                runtimeInstanceID: runtimeInstanceID,
                at: date
            )
            if transition.detectedRestart {
                do { try await repository?.markUsagePartial() }
                catch {
                    recordStartupIssue("Rule usage may be incomplete because runtime restart coverage could not be saved.")
                }
            }
            return transition.detectedRestart
        } catch {
            recordStartupIssue("Activity coverage may be incomplete because runtime continuity could not be saved.")
            return false
        }
    }

}
