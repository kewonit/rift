import RiftCore
import RiftIPC
import Foundation
import GRDB
import Testing
@testable import RiftControl

@Test func loweringHistoryLimitsPrunesImmediately() async throws {
    let context = try HistoryRetentionContext()
    defer { context.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let epoch = UUID()
    var events: [RuntimeEvent] = []
    events.append(try context.event(epoch: epoch, sequence: 1, at: now.addingTimeInterval(-172_800)))
    for index in 0..<150 {
        events.append(try context.event(
            epoch: epoch,
            sequence: UInt64(index + 2),
            at: now.addingTimeInterval(Double(index))
        ))
    }
    try await context.repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: events, droppedCount: 0),
        now: now.addingTimeInterval(150)
    )

    try await context.repository.configure(
        enabled: true,
        retentionDays: 1,
        maximumFlows: 100,
        now: now.addingTimeInterval(150)
    )

    let counts = try await context.repository.diagnosticCounts()
    let rows = try await context.repository.page(limit: 1_000)
    #expect(counts.visibleFlows == 100)
    #expect(rows.count == 100)
    #expect(rows.allSatisfy { $0.event.occurredAt > now.addingTimeInterval(-86_400) })
}

@Test func coverageGapsFollowRetentionAndAThousandRowCap() async throws {
    let context = try HistoryRetentionContext()
    defer { context.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    try await context.database.write { database in
        try database.execute(
            sql: "INSERT INTO coverage_gaps (provider_epoch, observed_at, reason, dropped_count) VALUES (?, ?, 'old', 1)",
            arguments: [UUID().uuidString.lowercased(), now.addingTimeInterval(-172_800).timeIntervalSince1970]
        )
        for index in 0..<1_001 {
            try database.execute(
                sql: "INSERT INTO coverage_gaps (provider_epoch, observed_at, reason, dropped_count) VALUES (?, ?, 'recent', 1)",
                arguments: [UUID().uuidString.lowercased(), now.addingTimeInterval(Double(index)).timeIntervalSince1970]
            )
        }
    }

    try await context.repository.configure(
        enabled: true,
        retentionDays: 1,
        maximumFlows: 50_000,
        now: now.addingTimeInterval(1_001)
    )

    let counts = try await context.repository.diagnosticCounts()
    let oldestReason = try await context.database.read { database in
        try String.fetchOne(
            database,
            sql: "SELECT reason FROM coverage_gaps ORDER BY observed_at ASC LIMIT 1"
        )
    }
    #expect(counts.coverageGaps == 1_000)
    #expect(oldestReason == "recent")
}

@Test func flowCapIncludesMoreThanFiftyThousandCloseAndStatisticsOnlyKeys() async throws {
    let context = try HistoryRetentionContext()
    defer { context.remove() }
    let start = Date(timeIntervalSince1970: 2_000_000_000)
    let epoch = UUID().uuidString.lowercased()
    let closedCount = 25_000
    let totalCount = 50_005
    try await context.database.write { database in
        for index in 0..<totalCount {
            let observedAt = start.addingTimeInterval(Double(index)).timeIntervalSince1970
            let closedAt: Double? = index < closedCount ? observedAt : nil
            try database.execute(
                sql: """
                    INSERT INTO flow_lifecycle
                        (provider_epoch, flow_id, decision_sequence, decision_at, closed_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [epoch, String(format: "flow-%05d", index), index + 1,
                            observedAt, closedAt]
            )
        }
    }

    try await context.repository.configure(
        enabled: true,
        retentionDays: 1,
        maximumFlows: 50_000,
        now: start.addingTimeInterval(Double(totalCount))
    )

    let counts = try await context.database.read { database in
        (
            total: try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM flow_lifecycle") ?? 0,
            closed: try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM flow_lifecycle WHERE closed_at IS NOT NULL"
            ) ?? 0,
            statistics: try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM flow_lifecycle WHERE closed_at IS NULL"
            ) ?? 0,
            oldestStatistics: try Double.fetchOne(
                database,
                sql: "SELECT MIN(decision_at) FROM flow_lifecycle WHERE closed_at IS NULL"
            )
        )
    }
    #expect(counts.total == 50_000)
    #expect(counts.closed == closedCount)
    #expect(counts.statistics == 25_000)
    #expect(counts.oldestStatistics == start.addingTimeInterval(25_005).timeIntervalSince1970)
}

private struct HistoryRetentionContext {
    let directory: URL
    let database: DatabasePool
    let repository: HistoryRepository

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
        repository = HistoryRepository(database: database)
    }

    func event(epoch: UUID, sequence: UInt64, at date: Date) throws -> RuntimeEvent {
        let flow = FlowDescriptor(
            flowID: UUID(), observedAt: date,
            sourceAppIdentity: nil, sourceProcessIdentity: nil,
            owner: .user(uid: 501), direction: .outgoing,
            transportProtocol: .tcp, localEndpoint: nil, remoteEndpoint: nil,
            observedHostname: nil, metadataConfidence: []
        )
        return RuntimeEvent(
            providerEpoch: epoch, sequence: sequence, occurredAt: date,
            flow: flow, action: .allow, reason: .concreteDecision, policy: nil
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
