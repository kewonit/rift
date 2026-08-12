import AbyssCore
import AbyssIPC
import Foundation
import GRDB
import Testing
@testable import AbyssControl

@Test func emptyRangeCoverageUsesIntervalsInsteadOfReturnedRows() async throws {
    let context = try CoverageTestContext()
    defer { context.remove() }
    let initial = try await context.repository.monitorSnapshot()
    let baseline = try #require(initial.coverage.recordingSince)
    let gap = HistoryCoverageInterval(
        startedAt: baseline.addingTimeInterval(20),
        endedAt: baseline.addingTimeInterval(30),
        reason: .appWriteFailure
    )
    try await context.repository.recordCoverageGap(
        gap,
        now: baseline.addingTimeInterval(31)
    )

    let snapshot = try await context.repository.monitorSnapshot()
    #expect(snapshot.rows.isEmpty)
    #expect(snapshot.coverage.coverage(
        from: baseline.addingTimeInterval(22),
        to: baseline.addingTimeInterval(24)
    ) == .partial)
    #expect(snapshot.coverage.coverage(
        from: baseline.addingTimeInterval(1),
        to: baseline.addingTimeInterval(10)
    ) == .complete)

    let summary = MonitorSummaryBuilder.build(from: [], rangeCoverage: .partial)
    #expect(summary.coverage == .partial)
    #expect(!summary.isComplete)
}

@Test func decisionBucketsReturnCoverageForEmptyAndPopulatedRanges() async throws {
    let context = try CoverageTestContext()
    defer { context.remove() }
    let baseline = try #require(
        try await context.repository.monitorSnapshot().coverage.recordingSince
    )
    try await context.repository.recordCoverageGap(
        HistoryCoverageInterval(
            startedAt: baseline.addingTimeInterval(60),
            endedAt: baseline.addingTimeInterval(120),
            reason: .extensionRingOverflow,
            droppedCount: 1
        ),
        now: baseline.addingTimeInterval(121)
    )

    let affected = try await context.repository.decisionBuckets(
        from: baseline.addingTimeInterval(70),
        to: baseline.addingTimeInterval(90),
        width: 60
    )
    #expect(affected.buckets.isEmpty)
    #expect(affected.coverage == .partial)

    let disjoint = try await context.repository.decisionBuckets(
        from: baseline.addingTimeInterval(1),
        to: baseline.addingTimeInterval(50),
        width: 60
    )
    #expect(disjoint.coverage == .complete)
    let invalid = try await context.repository.decisionBuckets(
        from: baseline,
        to: baseline.addingTimeInterval(1),
        width: .infinity
    )
    #expect(invalid.buckets.isEmpty)
    #expect(invalid.coverage == .gap)
}

@Test func sqliteWriteFailureReplaysWithoutDuplicatesAndLeavesDurableGap() async throws {
    let context = try CoverageTestContext()
    defer { context.remove() }
    let epoch = UUID()
    let firstAt = Date()
    let first = try coverageEvent(epoch: epoch, sequence: 1, at: firstAt)
    let failedBatch = RuntimeEventBatch(
        providerEpoch: epoch,
        events: [first],
        droppedCount: 0
    )
    try await context.database.write { database in
        try database.execute(sql: """
            CREATE TRIGGER fail_history_write BEFORE INSERT ON flow_events
            BEGIN SELECT RAISE(FAIL, 'simulated history write failure'); END
            """)
    }
    await #expect(throws: DatabaseError.self) {
        try await context.repository.ingest(failedBatch, now: firstAt)
    }

    var transient = TransientHistoryBuffer()
    transient.retainForReplay(failedBatch, observedAt: firstAt)
    transient.retainForReplay(failedBatch, observedAt: firstAt)
    let replay = transient.replaySnapshot()
    let interval = try #require(replay.failureInterval)
    #expect(replay.batches.flatMap(\.events).count == 1)
    try await context.database.write { database in
        try database.execute(sql: "DROP TRIGGER fail_history_write")
    }
    let second = try coverageEvent(
        epoch: epoch,
        sequence: 2,
        at: firstAt.addingTimeInterval(1)
    )
    let current = RuntimeEventBatch(providerEpoch: epoch, events: [second], droppedCount: 0)
    for _ in 0..<2 {
        try await context.repository.ingestRecovering(
            replayBatches: replay.batches,
            currentBatch: current,
            writeFailureInterval: interval,
            now: firstAt.addingTimeInterval(2)
        )
    }
    let conflictingDuplicate = try coverageEvent(
        epoch: epoch,
        sequence: 1,
        at: firstAt.addingTimeInterval(3)
    )
    try await context.repository.ingest(
        RuntimeEventBatch(
            providerEpoch: epoch,
            events: [conflictingDuplicate],
            droppedCount: 0
        ),
        now: firstAt.addingTimeInterval(3)
    )

    let snapshot = try await context.repository.monitorSnapshot()
    #expect(snapshot.rows.count == 2)
    #expect(Set(snapshot.rows.map(\.id)).count == 2)
    #expect(snapshot.coverage.intervals.filter { $0.reason == .appWriteFailure }.count == 1)
    #expect(snapshot.coverage.coverage(
        from: firstAt.addingTimeInterval(-1),
        to: firstAt.addingTimeInterval(2)
    ) == .partial)
}

@Test func disabledHistoryNeverReportsCompleteCoverage() async throws {
    let context = try CoverageTestContext()
    defer { context.remove() }
    let now = Date()
    try await context.repository.configure(
        enabled: false,
        retentionDays: 30,
        maximumFlows: 50_000,
        now: now
    )
    let snapshot = try await context.repository.monitorSnapshot()
    #expect(snapshot.coverage.coverage(
        from: now,
        to: now.addingTimeInterval(1)
    ) == .gap)
}

@Test func capacityEvictionAdvancesCoverageBaseline() async throws {
    let context = try CoverageTestContext()
    defer { context.remove() }
    let epoch = UUID()
    let start = Date()
    let events = try (0..<101).map {
        try coverageEvent(
            epoch: epoch,
            sequence: UInt64($0 + 1),
            at: start.addingTimeInterval(Double($0))
        )
    }
    try await context.repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: events, droppedCount: 0),
        now: start.addingTimeInterval(100)
    )
    try await context.repository.configure(
        enabled: true,
        retentionDays: 30,
        maximumFlows: 100,
        now: start.addingTimeInterval(101)
    )

    let snapshot = try await context.repository.monitorSnapshot()
    #expect(snapshot.rows.count == 100)
    #expect(snapshot.coverage.coverage(
        from: start.addingTimeInterval(-1),
        to: start.addingTimeInterval(0.5)
    ) == .partial)
    #expect(snapshot.coverage.coverage(
        from: start.addingTimeInterval(1),
        to: start.addingTimeInterval(101)
    ) == .complete)
}

private struct CoverageTestContext {
    let directory: URL
    let database: DatabasePool
    let repository: HistoryRepository

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
        repository = HistoryRepository(database: database)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func coverageEvent(epoch: UUID, sequence: UInt64, at date: Date) throws -> RuntimeEvent {
    let flow = FlowDescriptor(
        flowID: UUID(),
        observedAt: date,
        sourceAppIdentity: nil,
        sourceProcessIdentity: nil,
        owner: .user(uid: 501),
        direction: .outgoing,
        transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: nil,
        observedHostname: nil,
        metadataConfidence: []
    )
    return RuntimeEvent(
        providerEpoch: epoch,
        sequence: sequence,
        occurredAt: date,
        flow: flow,
        action: .allow,
        reason: .concreteDecision,
        policy: nil
    )
}
