import AbyssCore
import AbyssIPC
import Foundation
import GRDB
import Testing
@testable import AbyssControl

@Test func historyIngestionIsIdempotentAndRecordsCoverageGap() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = HistoryRepository(database: try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite")))
    let epoch = UUID()
    let event = RuntimeEvent(
        providerEpoch: epoch, sequence: 1, occurredAt: Date(), flow: try historyFlow(),
        action: .allow, reason: .concreteDecision, policy: nil
    )
    let batch = RuntimeEventBatch(providerEpoch: epoch, events: [event], droppedCount: 2)
    try await repository.ingest(batch, now: Date())
    try await repository.ingest(batch, now: Date())
    let rows = try await repository.page()
    #expect(rows.count == 1)
    #expect(rows.first?.coverage == .partial)
}

@Test func droppedHighWaterIsIdempotentAcrossDrainsEpochsAndRuntimeInstances() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    let repository = HistoryRepository(database: database)
    let firstRuntime = UUID()
    let secondRuntime = UUID()
    let firstEpoch = UUID()
    let secondEpoch = UUID()
    let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

    for count: UInt64 in [2, 2, 5] {
        try await repository.ingest(
            RuntimeEventBatch(providerEpoch: firstEpoch, events: [], droppedCount: count),
            now: observedAt,
            runtimeInstanceID: firstRuntime
        )
    }
    try await repository.ingest(
        RuntimeEventBatch(providerEpoch: secondEpoch, events: [], droppedCount: 6),
        now: observedAt.addingTimeInterval(1),
        runtimeInstanceID: firstRuntime
    )
    for count: UInt64 in [.max, .max] {
        try await repository.ingest(
            RuntimeEventBatch(providerEpoch: secondEpoch, events: [], droppedCount: count),
            now: observedAt.addingTimeInterval(2),
            runtimeInstanceID: secondRuntime
        )
    }

    let gaps = try database.read { database in
        try Row.fetchAll(
            database,
            sql: "SELECT provider_epoch, observed_at, reason, dropped_count FROM coverage_gaps"
        )
    }
    #expect(gaps.count == 2)
    let counts = gaps.map { row -> UInt64 in
        let stored: Int64 = row["dropped_count"]
        return UInt64(bitPattern: stored)
    }
    #expect(Set(counts) == [6, .max])
    let firstReason = "extensionRingOverflow:\(firstRuntime.uuidString.lowercased())"
    let first = try #require(gaps.first { ($0["reason"] as String) == firstReason })
    #expect((first["provider_epoch"] as String?) == secondEpoch.uuidString.lowercased())
    #expect((first["observed_at"] as Double)
        == observedAt.addingTimeInterval(1).timeIntervalSince1970)
}

@Test func historyMergesReorderedCloseWithoutDoubleCountingFlow() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = HistoryRepository(
        database: try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    )
    let epoch = UUID()
    let flow = try historyFlow()
    let decisionAt = Date(timeIntervalSince1970: 1_000)
    let closedAt = decisionAt.addingTimeInterval(5)
    let decision = RuntimeEvent(
        providerEpoch: epoch, sequence: 1, occurredAt: decisionAt, flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil
    )
    let close = RuntimeEvent(
        providerEpoch: epoch, sequence: 2, kind: .closed, occurredAt: closedAt, flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil,
        bytesInbound: 120, bytesOutbound: 80, flowEndReason: .networkExtensionReport
    )
    try await repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: [close], droppedCount: 0),
        now: closedAt
    )
    try await repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: [decision, close], droppedCount: 0),
        now: closedAt
    )
    let rows = try await repository.page()
    #expect(rows.count == 1)
    #expect(rows.first?.closedAt == closedAt)
    #expect(rows.first?.bytesInbound == 120)
    #expect(rows.first?.bytesOutbound == 80)
    let buckets = try await repository.decisionBuckets(
        from: decisionAt.addingTimeInterval(-60),
        to: closedAt.addingTimeInterval(60),
        width: 60,
        anchor: Date(timeIntervalSince1970: 950)
    )
    #expect(buckets.buckets.first?.start == Date(timeIntervalSince1970: 950))
    #expect(buckets.buckets.reduce(0) {
        $0 + $1.allowed + $1.denied + $1.unresolved
    } == 1)
}

@Test func historyMarksOpenFlowAbandonedAndAllowsLateCloseToReplaceReason() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = HistoryRepository(
        database: try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    )
    let epoch = UUID()
    let flow = try historyFlow()
    let decision = RuntimeEvent(
        providerEpoch: epoch, sequence: 1, occurredAt: Date(), flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil
    )
    try await repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: [decision], droppedCount: 0),
        now: Date()
    )
    try await repository.markOpenFlowsAbandoned()
    var page = try await repository.page()
    var row = try #require(page.first)
    #expect(row.closedAt == nil)
    #expect(row.flowEndReason == .appRestartAbandoned)

    let close = RuntimeEvent(
        providerEpoch: epoch, sequence: 2, kind: .closed,
        occurredAt: Date().addingTimeInterval(2), flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil,
        flowEndReason: .networkExtensionReport
    )
    try await repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: [close], droppedCount: 0),
        now: Date()
    )
    page = try await repository.page()
    row = try #require(page.first)
    #expect(row.closedAt != nil)
    #expect(row.flowEndReason == .networkExtensionReport)
}

@Test func historyMonitorSnapshotIsBoundedCompleteAndAtomicAcrossInsertion() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = HistoryRepository(
        database: try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    )
    let epoch = UUID()
    let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let initial = try (1...2).map { sequence in
        RuntimeEvent(
            providerEpoch: epoch,
            sequence: UInt64(sequence),
            occurredAt: observedAt.addingTimeInterval(Double(sequence)),
            flow: try historyFlow(),
            action: .allow,
            reason: .concreteDecision,
            policy: nil
        )
    }
    try await repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: initial, droppedCount: 0),
        now: observedAt.addingTimeInterval(2)
    )
    let bounded = try await repository.monitorSnapshot(maximum: 1)
    #expect(bounded.rows.map(\.event.sequence) == [2])
    #expect(!bounded.isComplete)

    let inserted = RuntimeEvent(
        providerEpoch: epoch,
        sequence: 3,
        occurredAt: observedAt.addingTimeInterval(3),
        flow: try historyFlow(),
        action: .deny,
        reason: .concreteDecision,
        policy: nil
    )
    async let concurrentSnapshot = repository.monitorSnapshot(maximum: 10)
    async let concurrentInsertion: Void = repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: [inserted], droppedCount: 0),
        now: inserted.occurredAt
    )
    let captured = try await concurrentSnapshot
    try await concurrentInsertion
    #expect(captured.rows.count == 2 || captured.rows.count == 3)
    #expect(Set(captured.rows.map(\.id)).count == captured.rows.count)
    #expect(captured.isComplete)
    let final = try await repository.monitorSnapshot(maximum: 10)
    #expect(final.rows.map(\.event.sequence) == [3, 2, 1])
    #expect(final.isComplete)
}

@Test func historyRoundTripsFullWidthByteCountersWithoutFalseExactClamping() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    let repository = HistoryRepository(database: database)
    let epoch = UUID()
    let flow = try historyFlow()
    let observedAt = Date(timeIntervalSince1970: 1_700_000_100)
    let decision = RuntimeEvent(
        providerEpoch: epoch, sequence: 1, occurredAt: observedAt, flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil
    )
    let close = RuntimeEvent(
        providerEpoch: epoch, sequence: 2, kind: .closed,
        occurredAt: observedAt.addingTimeInterval(1), flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil,
        bytesInbound: UInt64(Int64.max), bytesOutbound: UInt64(Int64.max),
        flowEndReason: .networkExtensionReport
    )
    let fullWidth = RuntimeEvent(
        providerEpoch: epoch, sequence: 3, kind: .statistics,
        occurredAt: observedAt.addingTimeInterval(2), flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil,
        bytesInbound: .max, bytesOutbound: UInt64(Int64.max) + 1
    )
    let lowerReport = RuntimeEvent(
        providerEpoch: epoch, sequence: 4, kind: .statistics,
        occurredAt: observedAt.addingTimeInterval(3), flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil,
        bytesInbound: 42, bytesOutbound: 42
    )
    try await repository.ingest(
        RuntimeEventBatch(
            providerEpoch: epoch,
            events: [decision, close, fullWidth, lowerReport],
            droppedCount: 0
        ),
        now: observedAt.addingTimeInterval(3)
    )
    let row = try #require(try await repository.page().first)
    #expect(row.coverage == .complete)
    #expect(row.bytesInbound == UInt64.max)
    #expect(row.bytesOutbound == UInt64(Int64.max) + 1)
    let displayed = MonitorQueryState(time: .all).apply(to: [row], geography: [:])
    let summary = MonitorSummaryBuilder.build(from: displayed)
    #expect(summary.received == .exact(.max))
    #expect(summary.sent == .exact(UInt64(Int64.max) + 1))

    let legacyFlow = try historyFlow()
    let legacyDecision = RuntimeEvent(
        providerEpoch: epoch, sequence: 5,
        occurredAt: observedAt.addingTimeInterval(4), flow: legacyFlow,
        action: .allow, reason: .concreteDecision, policy: nil
    )
    try await repository.ingest(
        RuntimeEventBatch(providerEpoch: epoch, events: [legacyDecision], droppedCount: 0),
        now: legacyDecision.occurredAt
    )
    try await database.write { database in
        try database.execute(
            sql: """
                UPDATE flow_lifecycle SET closed_at = ?, bytes_inbound = ?
                WHERE provider_epoch = ? AND flow_id = ?
                """,
            arguments: [legacyDecision.occurredAt.timeIntervalSince1970, Int64.max,
                        epoch.uuidString.lowercased(), legacyFlow.flowID.uuidString.lowercased()]
        )
    }
    let legacyRow = try #require(
        try await repository.page().first { $0.event.flow.flowID == legacyFlow.flowID }
    )
    #expect(legacyRow.coverage == .partial)
    #expect(legacyRow.bytesInbound == UInt64(Int64.max))
    let legacyDisplay = MonitorQueryState(time: .all).apply(to: [legacyRow], geography: [:])
    #expect(MonitorSummaryBuilder.build(from: legacyDisplay).received == .lowerBound(UInt64(Int64.max)))
}

@Test func transientHistoryIsBoundedNonpersistentAndMergesReorderedClose() throws {
    var buffer = TransientHistoryBuffer()
    let epoch = UUID()
    let flow = try historyFlow()
    let decisionAt = Date(timeIntervalSince1970: 3_000)
    let closedAt = decisionAt.addingTimeInterval(2)
    let close = RuntimeEvent(
        providerEpoch: epoch, sequence: 2, kind: .closed, occurredAt: closedAt, flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil,
        bytesInbound: 9, bytesOutbound: 7, flowEndReason: .networkExtensionReport
    )
    let decision = RuntimeEvent(
        providerEpoch: epoch, sequence: 1, occurredAt: decisionAt, flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil
    )
    buffer.ingest(RuntimeEventBatch(
        providerEpoch: epoch, events: [close, decision], droppedCount: 0
    ))
    let row = try #require(buffer.page().first)
    #expect(row.coverage == .gap)
    #expect(row.closedAt == closedAt)
    #expect(row.bytesInbound == 9)
    #expect(row.bytesOutbound == 7)

    for index in 0...TransientHistoryBuffer.maximumFlows {
        let nextFlow = FlowDescriptor(
            flowID: UUID(), observedAt: decisionAt.addingTimeInterval(Double(index)),
            sourceAppIdentity: nil, sourceProcessIdentity: nil, owner: flow.owner,
            direction: flow.direction, transportProtocol: flow.transportProtocol,
            localEndpoint: flow.localEndpoint, remoteEndpoint: flow.remoteEndpoint,
            observedHostname: flow.observedHostname, metadataConfidence: flow.metadataConfidence
        )
        buffer.ingest(RuntimeEventBatch(
            providerEpoch: epoch,
            events: [RuntimeEvent(
                providerEpoch: epoch, sequence: UInt64(index + 3),
                occurredAt: nextFlow.observedAt, flow: nextFlow,
                action: .allow, reason: .concreteDecision, policy: nil
            )],
            droppedCount: 0
        ))
    }
    #expect(buffer.page(limit: TransientHistoryBuffer.maximumFlows + 1).count
        == TransientHistoryBuffer.maximumFlows)
    buffer.clear()
    #expect(buffer.page().isEmpty)
}

@Test func corruptHistoryIsPreservedInQuarantineBeforeCleanRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.sqlite")
    let corrupt = Data("not a sqlite database".utf8)
    try corrupt.write(to: url)

    let result = try HistoryDatabase.openRecovering(
        at: url,
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(result.recovery?.quarantinedItemCount == 1)
    #expect(FileManager.default.fileExists(atPath: url.path))
    let quarantine = directory.appendingPathComponent("History Quarantine")
    let items = try FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)
    #expect(items.count == 1)
    #expect(try Data(contentsOf: try #require(items.first)) == corrupt)
}

@Test func operationalHistoryOpenErrorDoesNotQuarantine() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.sqlite")
    let original = Data("history that must remain in place".utf8)
    try original.write(to: url)

    #expect(throws: DatabaseError.self) {
        _ = try HistoryDatabase.openRecovering(
            at: url,
            now: Date(timeIntervalSince1970: 1_700_000_001),
            using: { _ in throw DatabaseError(resultCode: .SQLITE_FULL) }
        )
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("History Quarantine").path
    ))
}

@Test func operationalSQLiteErrorsAreNotClassifiedAsCorruption() {
    let operationalCodes: [ResultCode] = [
        .SQLITE_ERROR,
        .SQLITE_PERM,
        .SQLITE_BUSY,
        .SQLITE_LOCKED,
        .SQLITE_READONLY,
        .SQLITE_IOERR,
        .SQLITE_FULL,
        .SQLITE_CANTOPEN,
    ]
    for code in operationalCodes {
        #expect(!HistoryDatabase.isRecoverableCorruption(DatabaseError(resultCode: code)))
    }
}

@Test func futureHistorySchemaIsRejectedWithoutQuarantine() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let database = try HistoryDatabase.open(at: url)
    try database.write { database in
        try database.execute(
            sql: "INSERT INTO grdb_migrations (identifier) VALUES ('history-v999-future')"
        )
    }
    try database.close()

    #expect(throws: HistoryDatabaseError.unsupportedSchema) {
        _ = try HistoryDatabase.openRecovering(
            at: url,
            now: Date(timeIntervalSince1970: 1_700_000_002)
        )
    }
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("History Quarantine").path
    ))
}

@Test func failedCleanHistoryReopenRestoresOriginalDatabaseFamily() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("history.sqlite")
    let originalFamily = [
        "": Data("original-main".utf8),
        "-wal": Data("original-wal".utf8),
        "-shm": Data("original-shm".utf8),
    ]
    for (suffix, data) in originalFamily {
        try data.write(to: URL(fileURLWithPath: url.path + suffix))
    }

    var openAttempt = 0
    #expect(throws: DatabaseError.self) {
        _ = try HistoryDatabase.openRecovering(
            at: url,
            now: Date(timeIntervalSince1970: 1_700_000_003),
            using: { candidate in
                openAttempt += 1
                switch openAttempt {
                case 1:
                    throw DatabaseError(resultCode: .SQLITE_CORRUPT)
                case 2:
                    return try HistoryDatabase.open(at: candidate)
                default:
                    throw DatabaseError(resultCode: .SQLITE_FULL)
                }
            }
        )
    }
    #expect(openAttempt == 3)
    for (suffix, data) in originalFamily {
        #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) == data)
    }
    let quarantine = directory.appendingPathComponent("History Quarantine")
    let preservedReplacement = try FileManager.default.contentsOfDirectory(
        at: quarantine,
        includingPropertiesForKeys: nil
    )
    #expect(preservedReplacement.contains { $0.lastPathComponent.contains("-replacement.sqlite") })
}

@Test func historyExportsAreBoundedAndCSVNeutralizesFormulaPrefixes() throws {
    let row = MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: Date(timeIntervalSince1970: 1_000),
            flow: try historyFlow(), action: .allow, reason: .concreteDecision, policy: nil
        ),
        coverage: .complete
    )
    let json = try HistoryExportCodec.encode(
        rows: [row], format: .json, exportedAt: Date(timeIntervalSince1970: 2_000)
    )
    #expect(json.contains(Data("\"schemaVersion\":1".utf8)))
    #expect(HistoryExportCodec.csvCell(" =cmd") == "\"' =cmd\"")
    #expect(HistoryExportCodec.csvCell("safe \"value\"") == "\"safe \"\"value\"\"\"")
    #expect(throws: HistoryExportError.maximumBytesExceeded) {
        try HistoryExportCodec.encode(
            rows: [row], format: .json, exportedAt: Date(), maximumBytes: 1
        )
    }
}

private func historyFlow() throws -> FlowDescriptor {
    FlowDescriptor(
        flowID: UUID(), observedAt: Date(), sourceAppIdentity: nil,
        sourceProcessIdentity: nil, owner: .user(uid: 501), direction: .outgoing,
        transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("198.51.100.8"), port: 443, hostname: nil,
            hostnameCoverage: .absent, classes: [], interfaceSnapshotGeneration: 0
        ),
        observedHostname: nil, metadataConfidence: [.endpoint]
    )
}
