import RiftCore
import Darwin
import Foundation
import Testing
@testable import RiftControl

@Test func configurationBackupReaderRejectsSymbolicLinks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backup = try await makeConfigurationBackup(in: directory)
    let link = directory.appendingPathComponent("backup-link.sqlite")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: backup)

    #expect(throws: ConfigurationBackupReaderError.invalidFile) {
        try ConfigurationBackupReader.read(link)
    }
}

@Test func configurationBackupReaderRequiresOwnerOnlyModeAndExpectedOwner() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backup = try await makeConfigurationBackup(in: directory)

    #expect(throws: ConfigurationBackupReaderError.wrongOwner) {
        try ConfigurationBackupReader.read(
            backup,
            limits: backupLimits(expectedOwner: geteuid() &+ 1)
        )
    }

    try FileManager.default.setAttributes(
        [.posixPermissions: 0o640],
        ofItemAtPath: backup.path
    )
    #expect(throws: ConfigurationBackupReaderError.unsafePermissions) {
        try ConfigurationBackupReader.read(backup)
    }
}

@Test func configurationBackupReaderRejectsPathReplacementAfterSnapshot() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backup = try await makeConfigurationBackup(in: directory)
    let replacement = directory.appendingPathComponent("replacement.sqlite")
    let displaced = directory.appendingPathComponent("displaced.sqlite")
    try FileManager.default.copyItem(at: backup, to: replacement)

    #expect(throws: ConfigurationBackupReaderError.fileChangedWhileReading) {
        try ConfigurationBackupReader.read(
            backup,
            limits: .production,
            afterSnapshotRead: {
                try FileManager.default.moveItem(at: backup, to: displaced)
                try FileManager.default.copyItem(at: replacement, to: backup)
            }
        )
    }
}

@Test func configurationBackupReaderBoundsFilesPagesAndEncodedRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let backup = try await makeConfigurationBackup(in: directory, includeRule: true)
    let value = try ConfigurationBackupReader.read(backup)
    let restored = try #require(value)
    #expect(restored.rules.count == 1)

    #expect(throws: ConfigurationBackupReaderError.resourceLimitExceeded) {
        try ConfigurationBackupReader.read(
            backup,
            limits: backupLimits(maximumPageCount: 0)
        )
    }
    #expect(throws: ConfigurationBackupReaderError.resourceLimitExceeded) {
        try ConfigurationBackupReader.read(
            backup,
            limits: backupLimits(maximumPageBytes: 512)
        )
    }
    #expect(throws: ConfigurationBackupReaderError.resourceLimitExceeded) {
        try ConfigurationBackupReader.read(
            backup,
            limits: backupLimits(maximumAggregateEncodedBytes: 0)
        )
    }

    let oversized = directory.appendingPathComponent("oversized.sqlite")
    #expect(FileManager.default.createFile(atPath: oversized.path, contents: nil))
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: oversized.path
    )
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(ConfigurationBackupReadLimits.production.maximumFileBytes) + 1)
    try handle.close()
    #expect(throws: ConfigurationBackupReaderError.resourceLimitExceeded) {
        try ConfigurationBackupReader.read(oversized)
    }
}

private func makeConfigurationBackup(
    in directory: URL,
    includeRule: Bool = false
) async throws -> URL {
    let database = try ConfigurationDatabase.open(
        at: directory.appendingPathComponent("config.sqlite")
    )
    let repository = PolicyRepository(database: database)
    let lineage = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let rules: [Rule]
    if includeRule {
        rules = [try Rule(
            id: UUID(), lineageID: lineage, revision: 1,
            action: .filter(.allow), priority: .normal,
            process: .anyProcess, destination: .anyEndpoint,
            transportProtocol: .tcp, port: nil, direction: .outgoing,
            owner: .authorizedUser, createdAt: now, modifiedAt: now
        )]
    } else {
        rules = []
    }
    _ = try await repository.save(
        PolicyConfigurationDraft(
            lineageID: lineage,
            authorizedUID: UInt32(geteuid()),
            operationMode: .silentAllow,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: rules
        ),
        extensionHighWater: 0,
        commandKind: "backup-reader-test",
        redactedSummary: "fixture",
        now: now
    )
    return try await DailyConfigurationBackup(
        database: database,
        directory: directory.appendingPathComponent("Backups")
    ).runPreRestore(now: now)
}

private func backupLimits(
    maximumPageCount: Int? = nil,
    maximumPageBytes: Int? = nil,
    maximumAggregateEncodedBytes: Int? = nil,
    expectedOwner: uid_t? = nil
) -> ConfigurationBackupReadLimits {
    let production = ConfigurationBackupReadLimits.production
    return ConfigurationBackupReadLimits(
        maximumFileBytes: production.maximumFileBytes,
        maximumPageCount: maximumPageCount ?? production.maximumPageCount,
        minimumPageBytes: production.minimumPageBytes,
        maximumPageBytes: maximumPageBytes ?? production.maximumPageBytes,
        maximumRuleEncodedBytes: production.maximumRuleEncodedBytes,
        maximumAggregateEncodedBytes: maximumAggregateEncodedBytes
            ?? production.maximumAggregateEncodedBytes,
        expectedOwner: expectedOwner ?? production.expectedOwner
    )
}
