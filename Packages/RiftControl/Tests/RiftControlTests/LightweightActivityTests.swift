import Foundation
import GRDB
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

@Test func historyDeltasMatchFullSnapshotsAfterReorderedUpdatesAndExpiry() async throws {
    let context = try LightweightHistoryContext()
    defer { context.remove() }
    let initial = try await context.repository.monitorSnapshot()
    let flow = context.flow()
    let close = context.event(sequence: 3, flow: flow, kind: .closed, bytes: UInt64.max)
    let decision = context.event(sequence: 1, flow: flow)
    try await context.ingest([close])
    try await context.ingest([decision])
    var delta = try await context.repository.monitorChanges(after: #require(initial.cursor))
    #expect(!delta.requiresFullRefresh)
    #expect(delta.updatedRows.count == 1)
    #expect(delta.updatedRows.first?.bytesInbound == UInt64.max)
    var merged = try await MonitorHistoryMerge.applying(delta, to: initial)
    #expect(merged == (try await context.repository.monitorSnapshot()))

    // Duplicate decisions and older counter reports must not reset totals.
    try await context.ingest([decision, context.event(sequence: 2, flow: flow, kind: .statistics, bytes: 12)])
    delta = try await context.repository.monitorChanges(after: #require(merged.cursor))
    merged = try await MonitorHistoryMerge.applying(delta, to: merged)
    #expect(merged == (try await context.repository.monitorSnapshot()))
    #expect(merged.rows.first?.bytesInbound == UInt64.max)

    // A new ingestion expires the old flow and its events in the same transaction.
    let later = context.now.addingTimeInterval(31 * 86_400)
    let newFlow = context.flow(at: later)
    try await context.repository.ingest(
        RuntimeEventBatch(providerEpoch: context.epoch,
                          events: [context.event(sequence: 4, flow: newFlow, at: later)], droppedCount: 0),
        now: later
    )
    delta = try await context.repository.monitorChanges(after: #require(merged.cursor))
    #expect(delta.removedFlowKeys.contains(decisionRow(decision).flowKey))
    merged = try await MonitorHistoryMerge.applying(delta, to: merged)
    #expect(merged == (try await context.repository.monitorSnapshot()))
    let oldEvents = try await context.database.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM flow_events WHERE flow_id = ?",
                         arguments: [flow.flowID.uuidString.lowercased()])
    }
    #expect(oldEvents == 0)
}

@Test func historyCursorFallsBackAfterResetReplacementAndJournalEviction() async throws {
    let context = try LightweightHistoryContext()
    defer { context.remove() }
    let snapshot = try await context.repository.monitorSnapshot()
    let cursor = try #require(snapshot.cursor)
    try await context.repository.configure(enabled: false, retentionDays: 30, maximumFlows: 50_000)
    #expect(try await context.repository.monitorChanges(after: cursor).requiresFullRefresh)
    try await context.ingest([context.event(sequence: 1, flow: context.flow())])
    #expect(try await context.repository.monitorSnapshot().rows.isEmpty)

    let disabled = try await context.repository.monitorSnapshot()
    try await context.repository.configure(enabled: true, retentionDays: 30, maximumFlows: 50_000)
    #expect(try await context.repository.monitorChanges(after: #require(disabled.cursor)).requiresFullRefresh)
    let replacement = HistoryRepository(database: context.database)
    #expect(try await replacement.monitorChanges(after: cursor).requiresFullRefresh)

    let enabled = try await context.repository.monitorSnapshot()
    try await context.repository.clearHistory(now: context.now)
    #expect(try await context.repository.monitorChanges(after: #require(enabled.cursor)).requiresFullRefresh)

    var journal = HistoryChangeJournal()
    let expired = journal.cursor
    for _ in 0..<257 { journal.record([]) }
    #expect(journal.changes(after: expired) == nil)
    let beforeLargeBatch = journal.cursor
    let large = Set((0..<8_193).map { _ in HistoryFlowKey(providerEpoch: UUID(), flowID: UUID()) })
    journal.record(large)
    #expect(journal.changes(after: beforeLargeBatch) == nil)
    #expect(journal.changes(after: journal.cursor) == [])
}

@Test func historyWindowAndRollingDeltaKeepCompletenessAndByteUpdates() async throws {
    let context = try LightweightHistoryContext()
    defer { context.remove() }
    let events = (0..<8).map {
        context.event(sequence: UInt64($0 + 1), flow: context.flow(),
                      at: context.now.addingTimeInterval(Double($0)))
    }
    try await context.ingest(events)
    let window = try #require(MonitorTimeWindow(start: context.now.addingTimeInterval(3), end: nil))
    let snapshot = try await context.repository.monitorSnapshot(window: window)
    #expect(snapshot.isComplete && snapshot.rows.count == 5)
    let bounded = try await context.repository.monitorSnapshot(maximum: 2, window: window)
    #expect(!bounded.isComplete && bounded.rows.count == 2)
    let update = context.event(sequence: 9, flow: events[5].flow, kind: .statistics, bytes: 9_876)
    try await context.ingest([update])
    let delta = try await context.repository.monitorChanges(after: #require(snapshot.cursor))
    let rolling = try #require(MonitorTimeWindow(start: context.now.addingTimeInterval(5), end: nil))
    let merged = try await MonitorHistoryMerge.applying(delta, to: snapshot, window: rolling)
    #expect(merged == (try await context.repository.monitorSnapshot(window: rolling)))
    #expect(merged.rows.first { $0.event.sequence == 6 }?.bytesInbound == 9_876)
}

@Test func historyCoverageOnlyDeltaReclassifiesExistingRows() async throws {
    let context = try LightweightHistoryContext()
    defer { context.remove() }
    let event = context.event(sequence: 1, flow: context.flow())
    try await context.ingest([event])
    let snapshot = try await context.repository.monitorSnapshot()
    try await context.repository.recordCoverageGap(
        HistoryCoverageInterval(startedAt: context.now.addingTimeInterval(-1),
                                endedAt: context.now.addingTimeInterval(1), reason: .extensionRuntimeRestart),
        now: context.now
    )
    let delta = try await context.repository.monitorChanges(after: #require(snapshot.cursor))
    #expect(delta.updatedRows.isEmpty)
    let merged = try await MonitorHistoryMerge.applying(delta, to: snapshot)
    #expect(merged == (try await context.repository.monitorSnapshot()))
    #expect(merged.rows.first?.coverage != .complete)
}

@MainActor
@Test func visualRefreshCoalescesPausesAndSerializesCancellation() async throws {
    let coordinator = VisualRefreshCoordinator(interval: .milliseconds(80))
    var count = 0
    var active = 0
    var maximumActive = 0
    let operation: @MainActor () async -> Void = {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try? await Task.sleep(for: .milliseconds(15))
        if !Task.isCancelled { count += 1 }
    }
    coordinator.request(operation: operation)
    try await Task.sleep(for: .milliseconds(25))
    #expect(count == 0)
    coordinator.setVisible(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(count == 1)
    for _ in 0..<100 { coordinator.request(operation: operation) }
    try await Task.sleep(for: .milliseconds(25))
    #expect(count == 1)
    coordinator.setVisible(false)
    try await Task.sleep(for: .milliseconds(100))
    #expect(count == 1)
    coordinator.setVisible(true)
    try await Task.sleep(for: .milliseconds(30))
    #expect(count == 2)
    coordinator.request(immediate: true, operation: operation)
    try await Task.sleep(for: .milliseconds(2))
    coordinator.setVisible(false)
    coordinator.setVisible(true)
    try await Task.sleep(for: .milliseconds(35))
    #expect(count == 3 && maximumActive == 1)
    coordinator.stop()
}

@Test func decisionBucketsReuseSourceWithoutSearchOrSelectedRangeFiltering() async throws {
    let context = try LightweightHistoryContext()
    defer { context.remove() }
    try await context.ingest((0..<5).map {
        context.event(sequence: UInt64($0 + 1), flow: context.flow(),
                      at: context.now.addingTimeInterval(Double($0 * 60)))
    })
    let now = context.now.addingTimeInterval(300)
    let query = MonitorQueryState(search: "no matching application", time: .tenMinutes,
                                  selectedTimeRange: context.now...context.now.addingTimeInterval(30))
    let snapshot = try await context.repository.monitorSnapshot()
    let result = MonitorDecisionBuckets.build(rows: snapshot.rows, query: query, now: now,
                                              coverage: snapshot.coverage, isComplete: snapshot.isComplete)
    let window = try #require(query.baseTimeWindow(now: now))
    let stored = try await context.repository.decisionBuckets(
        from: #require(window.start), to: #require(window.end), width: query.time.decisionBucketWidth,
        anchor: window.start
    )
    #expect(result == stored)
}

@Test func cachedMonitorMatcherRespectsExpiryPolicyAndEnforcementChanges() async throws {
    let context = LightweightEvents()
    let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAM", signingIdentifier: "example.client"
    ))
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: context.now, sourceAppIdentity: identity, sourceProcessIdentity: identity,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(address: try IPAddress("203.0.113.1"), port: 443, hostname: nil,
                                 hostnameCoverage: .absent, classes: [], interfaceSnapshotGeneration: 1),
        observedHostname: nil, metadataConfidence: [.appIdentity, .endpoint]
    )
    let row = decisionRow(context.event(sequence: 1, flow: flow))
    let lineage = UUID()
    let rule = try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .normal,
        process: .anyProcess, destination: .anyEndpoint, transportProtocol: .anySupportedProtocol,
        port: nil, direction: .bidirectional, owner: .authorizedUser,
        expiresAt: context.now.addingTimeInterval(1), createdAt: context.now, modifiedAt: context.now
    )
    let configuration = PolicyConfigurationDraft(lineageID: lineage, authorizedUID: 501,
        operationMode: .silentAllow, activeProfileID: nil, enabledLocalGroupIDs: [], rules: [rule])
    let tuple = PolicyTuple(lineageID: lineage, generation: 1, hash: Data(repeating: 1, count: 32))
    let snapshot = RuleWorkspaceSnapshot(configuration: configuration, enforcementState: .enforced,
                                          desiredTuple: tuple, generation: 1, usage: [:])
    let cache = MonitorCoverageCache()
    #expect(try await cache.evaluate([row], snapshot: snapshot, enforcementState: .enforced,
                                    now: context.now)[row.id]?.state == .broader)
    #expect(try await cache.evaluate([row], snapshot: snapshot, enforcementState: .applyFailed,
                                    now: context.now)[row.id]?.state == .applyFailed)
    let expiredAt = context.now.addingTimeInterval(2)
    let expired = try await cache.evaluate([row], snapshot: snapshot, enforcementState: .enforced, now: expiredAt)
    #expect(expired == MonitorCoverageEvaluator.evaluate([row], configuration: configuration,
        enforcementState: .enforced, desiredTuple: tuple, now: expiredAt))
    #expect(expired[row.id]?.winningRuleID == nil)
    let empty = PolicyConfigurationDraft(lineageID: lineage, authorizedUID: 501,
        operationMode: .silentAllow, activeProfileID: nil, enabledLocalGroupIDs: [], rules: [])
    let nextTuple = PolicyTuple(lineageID: lineage, generation: 2, hash: Data(repeating: 2, count: 32))
    let next = RuleWorkspaceSnapshot(configuration: empty, enforcementState: .enforced,
                                      desiredTuple: nextTuple, generation: 2, usage: [:])
    #expect(try await cache.evaluate([row], snapshot: next, enforcementState: .enforced,
                                    now: context.now)[row.id]?.winningRuleID == nil)
}

private func decisionRow(_ event: RuntimeEvent) -> MonitorEventRow {
    MonitorEventRow(event: event, coverage: .complete)
}

struct LightweightEvents {
    let epoch = UUID()
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    func flow(at date: Date? = nil) -> FlowDescriptor {
        FlowDescriptor(flowID: UUID(), observedAt: date ?? now, sourceAppIdentity: nil,
                       sourceProcessIdentity: nil, owner: .user(uid: 501), direction: .outgoing,
                       transportProtocol: .tcp, localEndpoint: nil, remoteEndpoint: nil,
                       observedHostname: nil, metadataConfidence: [])
    }

    func event(sequence: UInt64, flow: FlowDescriptor? = nil, kind: RuntimeEventKind = .decision,
               bytes: UInt64? = nil, at date: Date? = nil) -> RuntimeEvent {
        RuntimeEvent(providerEpoch: epoch, sequence: sequence, kind: kind, occurredAt: date ?? now,
                     flow: flow ?? self.flow(), action: .allow, reason: .concreteDecision, policy: nil,
                     bytesInbound: bytes, bytesOutbound: bytes,
                     flowEndReason: kind == .closed ? .networkExtensionReport : nil)
    }
}

struct LightweightHistoryContext {
    let directory: URL
    let database: DatabasePool
    let repository: HistoryRepository
    private let events = LightweightEvents()
    var epoch: UUID { events.epoch }
    var now: Date { events.now }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
        repository = HistoryRepository(database: database)
    }

    func flow(at date: Date? = nil) -> FlowDescriptor { events.flow(at: date) }
    func event(sequence: UInt64, flow: FlowDescriptor, kind: RuntimeEventKind = .decision,
               bytes: UInt64? = nil, at date: Date? = nil) -> RuntimeEvent {
        events.event(sequence: sequence, flow: flow, kind: kind, bytes: bytes, at: date)
    }
    func ingest(_ events: [RuntimeEvent]) async throws {
        try await repository.ingest(RuntimeEventBatch(providerEpoch: epoch, events: events, droppedCount: 0), now: now)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
