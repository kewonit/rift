import Foundation
import GRDB
import Testing
@testable import AbyssControl

@Test func firstRuntimeAndSameRuntimeReconnectRemainComplete() async throws {
    let context = try RuntimeCoverageTestContext()
    defer { context.remove() }
    let runtimeID = UUID()
    let firstAt = try await context.baseline().addingTimeInterval(1)
    let secondAt = firstAt.addingTimeInterval(2)

    #expect(try await context.repository.recordAuthenticatedRuntimeDrain(
        runtimeInstanceID: runtimeID,
        at: firstAt
    ) == .firstObservation)
    #expect(try await context.repository.recordAuthenticatedRuntimeDrain(
        runtimeInstanceID: runtimeID,
        at: secondAt
    ) == .sameRuntime)

    let snapshot = try await context.repository.monitorSnapshot()
    #expect(snapshot.coverage.intervals.allSatisfy { $0.reason != .extensionRuntimeRestart })
    #expect(snapshot.coverage.coverage(
        from: firstAt,
        to: secondAt.addingTimeInterval(1)
    ) == .complete)
    let stored = try await context.database.read { database -> (String?, Double?) in
        let row = try Row.fetchOne(database, sql: "SELECT last_runtime_instance_id, last_successful_drain_at FROM history_coverage_state WHERE singleton_id = 1")
        return (row?["last_runtime_instance_id"], row?["last_successful_drain_at"])
    }
    #expect(stored.0 == runtimeID.uuidString.lowercased())
    #expect(stored.1 == secondAt.timeIntervalSince1970)
}

@Test func changedRuntimeWithZeroDropsRecordsOnePartialIntervalAcrossDuplicateSignals() async throws {
    let context = try RuntimeCoverageTestContext()
    defer { context.remove() }
    let firstAt = try await context.baseline().addingTimeInterval(1)
    let restartAt = firstAt.addingTimeInterval(30)
    let firstRuntime = UUID()
    let secondRuntime = UUID()
    _ = try await context.repository.recordAuthenticatedRuntimeDrain(
        runtimeInstanceID: firstRuntime,
        at: firstAt
    )

    let transition = try await context.repository.recordAuthenticatedRuntimeDrain(
        runtimeInstanceID: secondRuntime,
        at: restartAt
    )
    #expect(transition.detectedRestart)
    guard case .runtimeRestart(let interval) = transition else {
        Issue.record("Expected a runtime restart transition")
        return
    }
    #expect(interval.startedAt == firstAt)
    #expect(interval.endedAt == restartAt)
    #expect(interval.droppedCount == 0)
    #expect(try await context.repository.recordAuthenticatedRuntimeDrain(
        runtimeInstanceID: secondRuntime,
        at: restartAt.addingTimeInterval(1)
    ) == .sameRuntime)

    let snapshot = try await context.repository.monitorSnapshot()
    let restartIntervals = snapshot.coverage.intervals.filter {
        $0.reason == .extensionRuntimeRestart
    }
    #expect(restartIntervals == [interval])
    #expect(snapshot.coverage.coverage(
        from: firstAt,
        to: restartAt.addingTimeInterval(1)
    ) == .partial)
}

@Test func runtimeRestartAfterAppAbsenceUsesPersistedLastSuccessfulDrain() async throws {
    let context = try RuntimeCoverageTestContext()
    defer { context.remove() }
    let firstAt = try await context.baseline().addingTimeInterval(1)
    let restartAt = firstAt.addingTimeInterval(300)
    _ = try await context.repository.recordAuthenticatedRuntimeDrain(
        runtimeInstanceID: UUID(),
        at: firstAt
    )

    let reopened = HistoryRepository(database: context.database)
    let transition = try await reopened.recordAuthenticatedRuntimeDrain(
        runtimeInstanceID: UUID(),
        at: restartAt
    )
    guard case .runtimeRestart(let interval) = transition else {
        Issue.record("Expected persisted runtime state to detect the restart")
        return
    }
    #expect(interval.startedAt == firstAt)
    #expect(interval.endedAt == restartAt)
}

@Test func runtimeRestartCanOnlyDowngradeCompleteRuleUsageToPartial() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    let repository = PolicyRepository(database: database)

    try await repository.markUsagePartial()
    #expect(try await usageCoverage(in: database) == .partial)
    try await repository.markUsageGap()
    try await repository.markUsagePartial()
    #expect(try await usageCoverage(in: database) == .gap)
}

private struct RuntimeCoverageTestContext {
    let directory: URL
    let database: DatabasePool
    let repository: HistoryRepository

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
        repository = HistoryRepository(database: database)
    }

    func baseline() async throws -> Date {
        try #require(try await repository.monitorSnapshot().coverage.recordingSince)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func usageCoverage(in database: DatabasePool) async throws -> HistoryCoverage {
    try await database.read { database in
        let value = try String.fetchOne(
            database,
            sql: "SELECT state FROM usage_coverage WHERE singleton_id = 1"
        )
        return value.flatMap(HistoryCoverage.init(rawValue:)) ?? .gap
    }
}
