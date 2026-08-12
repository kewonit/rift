import AbyssCore
import Foundation
import GRDB
import Testing
@testable import AbyssControl

@Test func policySaveRejectsStaleGenerationWithoutChangingConfiguration() async throws {
    let context = try TestPolicyContext()
    defer { context.remove() }
    let initial = context.draft(mode: .silentAllow)
    let saved = try await context.repository.save(
        initial,
        extensionHighWater: 0,
        expectedGeneration: 0,
        commandKind: "initial",
        redactedSummary: "initial",
        now: Date(timeIntervalSince1970: 100)
    )
    let stale = context.draft(mode: .silentDeny)

    await #expect(throws: PolicyRepositoryError.generationConflict) {
        try await context.repository.save(
            stale,
            extensionHighWater: 0,
            expectedGeneration: saved.tuple.generation - 1,
            commandKind: "stale",
            redactedSummary: "stale",
            now: Date(timeIntervalSince1970: 101)
        )
    }
    #expect(try await context.repository.currentConfiguration()?.operationMode == .silentAllow)
    #expect(try await context.repository.newestDesiredPolicy()?.tuple == saved.tuple)
}

@Test func policySaveValidatesRelationshipsBeforeWriting() async throws {
    let context = try TestPolicyContext()
    defer { context.remove() }
    let invalid = PolicyConfigurationDraft(
        lineageID: context.lineage,
        authorizedUID: 501,
        operationMode: .silentAllow,
        activeProfileID: UUID(),
        enabledLocalGroupIDs: [],
        rules: []
    )

    await #expect(throws: PolicyConfigurationValidationError.invalidRelationship) {
        try await context.repository.save(
            invalid,
            extensionHighWater: 0,
            expectedGeneration: 0,
            commandKind: "invalid",
            redactedSummary: "invalid",
            now: Date(timeIntervalSince1970: 100)
        )
    }
    #expect(try await context.repository.currentConfiguration() == nil)
}

@Test func configurationReaderRejectsRowIdentifierMismatch() async throws {
    let context = try TestPolicyContext()
    defer { context.remove() }
    let now = Date(timeIntervalSince1970: 100)
    let rule = try Rule(
        id: UUID(), lineageID: context.lineage, revision: 1,
        action: .filter(.allow), priority: .normal,
        process: .anyProcess, destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol, port: nil,
        direction: .outgoing, owner: .authorizedUser,
        createdAt: now, modifiedAt: now
    )
    _ = try await context.repository.save(
        context.draft(rules: [rule]),
        extensionHighWater: 0,
        expectedGeneration: 0,
        commandKind: "rule",
        redactedSummary: "one",
        now: now
    )
    try await context.database.write { database in
        try database.execute(
            sql: "UPDATE rules SET id = ?",
            arguments: [UUID().uuidString.lowercased()]
        )
    }

    await #expect(throws: PolicyRepositoryError.acknowledgementMismatch) {
        try await context.repository.currentConfiguration()
    }
}

@Test func restoreRecoveryMarkerSurvivesRepositoryRecreationAndClearsAfterTarget() async throws {
    let context = try TestPolicyContext()
    defer { context.remove() }
    let saved = try await context.repository.save(
        context.draft(),
        extensionHighWater: 0,
        expectedGeneration: 0,
        restoreBackupName: "pre-restore-100-deadbeef.sqlite",
        commandKind: "restore",
        redactedSummary: "restore",
        now: Date(timeIntervalSince1970: 100)
    )
    let reopened = PolicyRepository(database: context.database)

    let recovery = try await reopened.pendingRestoreRecovery()
    #expect(recovery?.backupName == "pre-restore-100-deadbeef.sqlite")
    #expect(recovery?.targetGeneration == saved.tuple.generation)
    try await reopened.clearPendingRestoreRecovery(
        throughGeneration: saved.tuple.generation - 1
    )
    #expect(try await reopened.pendingRestoreRecovery() != nil)
    try await reopened.clearPendingRestoreRecovery(throughGeneration: saved.tuple.generation)
    #expect(try await reopened.pendingRestoreRecovery() == nil)
}

@Test func consecutivePendingRestorePreservesOriginalRollbackAnchor() async throws {
    let context = try TestPolicyContext()
    defer { context.remove() }
    let firstBackup = "pre-restore-100-deadbeef.sqlite"
    let first = try await context.repository.save(
        context.draft(mode: .silentAllow),
        extensionHighWater: 0,
        expectedGeneration: 0,
        restoreBackupName: firstBackup,
        commandKind: "first-restore",
        redactedSummary: "first",
        now: Date(timeIntervalSince1970: 100)
    )

    await #expect(throws: PolicyRepositoryError.restoreRecoveryInProgress) {
        try await context.repository.save(
            context.draft(mode: .silentDeny),
            extensionHighWater: first.tuple.generation,
            expectedGeneration: first.tuple.generation,
            restoreBackupName: "pre-restore-101-feedface.sqlite",
            commandKind: "second-restore",
            redactedSummary: "second",
            now: Date(timeIntervalSince1970: 101)
        )
    }

    let recovery = try await context.repository.pendingRestoreRecovery()
    #expect(recovery?.backupName == firstBackup)
    #expect(recovery?.targetGeneration == first.tuple.generation)
    #expect(try await context.repository.currentConfiguration()?.operationMode == .silentAllow)
    #expect(try await context.repository.newestDesiredPolicy()?.tuple == first.tuple)
}

@Test func policyOutboxAndAuditAreBounded() async throws {
    let context = try TestPolicyContext()
    defer { context.remove() }
    var generation: UInt64 = 0
    for index in 0..<5 {
        let saved = try await context.repository.save(
            context.draft(),
            extensionHighWater: 0,
            expectedGeneration: generation,
            commandKind: "save",
            redactedSummary: "save",
            now: Date(timeIntervalSince1970: Double(100 + index))
        )
        generation = saved.tuple.generation
    }
    let auditGeneration = generation
    try await context.database.write { database in
        for index in 0..<1_001 {
            try database.execute(
                sql: "INSERT INTO command_audit (generation, command_kind, created_at, redacted_summary) VALUES (?, 'fixture', ?, 'fixture')",
                arguments: [Int64(auditGeneration), Double(index)]
            )
        }
    }
    _ = try await context.repository.save(
        context.draft(),
        extensionHighWater: 0,
        expectedGeneration: generation,
        commandKind: "prune",
        redactedSummary: "prune",
        now: Date(timeIntervalSince1970: 200)
    )

    let counts = try await context.database.read { database in
        (
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM policy_outbox") ?? 0,
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM command_audit") ?? 0
        )
    }
    #expect(counts.0 == 3)
    #expect(counts.1 == 1_000)
}

private struct TestPolicyContext {
    let directory: URL
    let database: DatabasePool
    let repository: PolicyRepository
    let lineage = UUID()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
        repository = PolicyRepository(database: database)
    }

    func draft(mode: OperationMode = .silentAllow, rules: [Rule] = []) -> PolicyConfigurationDraft {
        PolicyConfigurationDraft(
            lineageID: lineage,
            authorizedUID: 501,
            operationMode: mode,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: rules
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
