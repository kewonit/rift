import Foundation
import Testing
@testable import AbyssControl

@Test func dailyBackupUsesSQLiteOnlineBackupAndRunsOncePerDay() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    let backup = DailyConfigurationBackup(
        database: database,
        directory: directory.appendingPathComponent("Backups")
    )
    let first = try await backup.runIfNeeded(now: Date(timeIntervalSince1970: 1_700_000_000))
    let second = try await backup.runIfNeeded(now: Date(timeIntervalSince1970: 1_700_000_100))

    #expect(first != nil)
    #expect(second == nil)
    #expect(FileManager.default.fileExists(atPath: try #require(first).path))
}

@Test func preRestoreBackupAlwaysRunsAndRetainsSeven() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    let backupDirectory = directory.appendingPathComponent("Backups")
    let backup = DailyConfigurationBackup(database: database, directory: backupDirectory)

    var paths = Set<String>()
    for offset in 0..<8 {
        let url = try await backup.runPreRestore(
            now: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset))
        )
        paths.insert(url.path)
    }

    #expect(paths.count == 8)
    let retained = try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("pre-restore-") && $0.pathExtension == "sqlite" }
    #expect(retained.count == 7)
    for url in retained {
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}

@Test func preRestoreBackupCanBeReadWithoutImportingItsGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    let repository = PolicyRepository(database: database)
    let lineage = UUID()
    let original = PolicyConfigurationDraft(
        lineageID: lineage,
        authorizedUID: UInt32(geteuid()),
        operationMode: .silentAllow,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: []
    )
    _ = try await repository.save(
        original,
        extensionHighWater: 0,
        commandKind: "test",
        redactedSummary: "original",
        now: Date(timeIntervalSince1970: 1_000)
    )
    let backup = DailyConfigurationBackup(
        database: database,
        directory: directory.appendingPathComponent("Backups")
    )
    let url = try await backup.runPreRestore(now: Date(timeIntervalSince1970: 2_000))
    let value = try ConfigurationBackupReader.read(url)
    let restored = try #require(value)
    #expect(restored.lineageID == lineage)
    #expect(restored.operationMode == .silentAllow)
    #expect(restored.rules.isEmpty)
}
