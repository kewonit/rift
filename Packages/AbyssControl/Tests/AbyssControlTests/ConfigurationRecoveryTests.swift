import Foundation
import GRDB
import Testing
@testable import AbyssControl

@Test func configurationRecoveryStagesSavedConfigurationBeforeReplacingOriginal() async throws {
    let directory = try recoveryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.sqlite")
    let invalid = Data("invalid configuration database".utf8)
    let journal = Data("invalid journal".utf8)
    try invalid.write(to: url)
    try journal.write(to: URL(fileURLWithPath: url.path + "-wal"))
    let lineage = UUID()

    let recovered = try await ConfigurationDatabase.recoverByQuarantining(
        at: url,
        now: Date(timeIntervalSince1970: 123)
    ) { database in
        let repository = PolicyRepository(database: database)
        return try await repository.save(
            PolicyConfigurationDraft(
                lineageID: lineage,
                authorizedUID: 501,
                operationMode: .silentAllow,
                activeProfileID: nil,
                enabledLocalGroupIDs: [],
                rules: []
            ),
            extensionHighWater: 0,
            commandKind: "recoveryTest",
            redactedSummary: "rules=0",
            now: Date(timeIntervalSince1970: 124)
        )
    }
    let repository = PolicyRepository(database: recovered.result.database)
    let quarantine = directory.appendingPathComponent("Configuration Quarantine")
    let files = try FileManager.default.contentsOfDirectory(
        at: quarantine,
        includingPropertiesForKeys: nil
    )
    let preservedDatabase = try #require(files.first {
        $0.lastPathComponent.hasPrefix("configuration-123-")
            && $0.lastPathComponent.hasSuffix(".sqlite")
            && !$0.lastPathComponent.contains("replacement")
    })
    let preservedJournal = try #require(files.first {
        $0.lastPathComponent.hasSuffix(".sqlite-wal")
            && !$0.lastPathComponent.contains("replacement")
    })

    #expect(recovered.result.recovery.quarantinedItemCount == 2)
    #expect(try Data(contentsOf: preservedDatabase) == invalid)
    #expect(try Data(contentsOf: preservedJournal) == journal)
    #expect(try await repository.currentConfiguration()?.lineageID == lineage)
    #expect(recovered.value.tuple.generation == 1)
    try recovered.result.database.close()
}

@Test func futureConfigurationSchemaIsRejectedWithoutMutationOrQuarantine() async throws {
    let directory = try recoveryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.sqlite")
    let database = try ConfigurationDatabase.open(at: url)
    defer { try? database.close() }
    try await database.write { database in
        try database.execute(
            sql: "INSERT INTO grdb_migrations (identifier) VALUES ('configuration-v999-future')"
        )
    }
    #expect(FileManager.default.fileExists(atPath: url.path + "-wal"))
    let before = try databaseFamily(at: url)

    do {
        _ = try ConfigurationDatabase.open(at: url)
        Issue.record("Expected a future configuration schema to be rejected")
    } catch let error as ConfigurationDatabaseError {
        #expect(error == .unsupportedSchema)
    }
    #expect(try databaseFamily(at: url) == before)

    do {
        _ = try await ConfigurationDatabase.recoverByQuarantining(
            at: url,
            now: Date(timeIntervalSince1970: 125)
        ) { _ in
            throw RecoveryTestError.populateWasCalled
        }
        Issue.record("Expected recovery to reject a future configuration schema")
    } catch let error as ConfigurationDatabaseError {
        #expect(error == .unsupportedSchema)
    }
    #expect(try databaseFamily(at: url) == before)
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("Configuration Quarantine").path
    ))
}

@Test func recoveryPopulateFailureLeavesOriginalFamilyInPlace() async throws {
    let directory = try recoveryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.sqlite")
    try Data("original".utf8).write(to: url)
    try Data("original wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
    let before = try databaseFamily(at: url)

    do {
        _ = try await ConfigurationDatabase.recoverByQuarantining(
            at: url,
            now: Date(timeIntervalSince1970: 126)
        ) { _ in
            throw RecoveryTestError.populateFailed
        }
        Issue.record("Expected staged population to fail")
    } catch let error as RecoveryTestError {
        #expect(error == .populateFailed)
    }

    #expect(try databaseFamily(at: url) == before)
}

@Test func recoveryPreparesReplacementBeforeRootTransitionAndCleansUpOnRefusal() async throws {
    let directory = try recoveryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.sqlite")
    let original = Data("original invalid database".utf8)
    try original.write(to: url)
    let prepared = PreparedRecoveryFlag()

    do {
        _ = try await ConfigurationDatabase.recoverByQuarantining(
            at: url,
            now: Date(timeIntervalSince1970: 126.5),
            beforePromotion: {
                guard await prepared.value else {
                    throw RecoveryTestError.populateWasCalled
                }
                throw RecoveryTestError.beforePromotionFailed
            },
            populate: { _ in
                await prepared.markPrepared()
            }
        )
        Issue.record("Expected the root transition to refuse promotion")
    } catch let error as RecoveryTestError {
        #expect(error == .beforePromotionFailed)
    }

    #expect(try Data(contentsOf: url) == original)
    let quarantine = directory.appendingPathComponent("Configuration Quarantine")
    #expect((try FileManager.default.contentsOfDirectory(atPath: quarantine.path)).isEmpty)
}

@Test func failedReplacementReopenRestoresOriginalConfigurationFamily() async throws {
    let directory = try recoveryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.sqlite")
    try Data("original".utf8).write(to: url)
    try Data("original wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
    let before = try databaseFamily(at: url)

    do {
        _ = try await ConfigurationDatabase.recoverByQuarantining(
            at: url,
            now: Date(timeIntervalSince1970: 127),
            using: { candidate in
                if candidate.standardizedFileURL == url.standardizedFileURL {
                    throw RecoveryTestError.reopenFailed
                }
                return try ConfigurationDatabase.open(at: candidate)
            },
            populate: { _ in () }
        )
        Issue.record("Expected replacement reopen to fail")
    } catch let error as RecoveryTestError {
        #expect(error == .reopenFailed)
    }

    #expect(try databaseFamily(at: url) == before)
}

@Test func permissionFailureAfterMoveRestoresEveryMovedItem() throws {
    let directory = try recoveryTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.sqlite")
    let destination = directory.appendingPathComponent("destination.sqlite")
    try Data("main".utf8).write(to: source)
    try Data("wal".utf8).write(to: URL(fileURLWithPath: source.path + "-wal"))
    let before = try databaseFamily(at: source)

    do {
        _ = try ConfigurationDatabase.moveDatabaseFamily(
            from: source,
            to: destination,
            setPermissions: { _ in throw RecoveryTestError.permissionFailed }
        )
        Issue.record("Expected permission application to fail")
    } catch let error as RecoveryTestError {
        #expect(error == .permissionFailed)
    }

    #expect(try databaseFamily(at: source) == before)
    #expect(try databaseFamily(at: destination).isEmpty)
}

private enum RecoveryTestError: Error, Equatable {
    case populateWasCalled
    case populateFailed
    case reopenFailed
    case permissionFailed
    case beforePromotionFailed
}

private actor PreparedRecoveryFlag {
    private(set) var value = false

    func markPrepared() { value = true }
}

private func recoveryTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func databaseFamily(at url: URL) throws -> [String: Data] {
    var values: [String: Data] = [:]
    for suffix in ["", "-wal", "-shm"] {
        let member = URL(fileURLWithPath: url.path + suffix)
        if FileManager.default.fileExists(atPath: member.path) {
            values[suffix] = try Data(contentsOf: member)
        }
    }
    return values
}
