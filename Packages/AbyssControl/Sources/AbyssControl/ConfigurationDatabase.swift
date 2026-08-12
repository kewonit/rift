import Foundation
import GRDB

public enum ConfigurationDatabaseError: Error, Sendable, Equatable {
    case invalidDatabaseDirectory
    case integrityCheckFailed
    case unsupportedSchema
    case schemaPreflightCleanupFailed
    case recoveryPreparationCleanupFailed
    case recoveryRollbackFailed
}

public struct ConfigurationDatabaseRecovery: Sendable, Hashable {
    public let quarantinedItemCount: Int
    public let occurredAt: Date

    public init(quarantinedItemCount: Int, occurredAt: Date) {
        self.quarantinedItemCount = quarantinedItemCount
        self.occurredAt = occurredAt
    }
}

public struct ConfigurationDatabaseOpenResult: Sendable {
    public let database: DatabasePool
    public let recovery: ConfigurationDatabaseRecovery

    public init(database: DatabasePool, recovery: ConfigurationDatabaseRecovery) {
        self.database = database
        self.recovery = recovery
    }
}

public enum ConfigurationDatabase {
    public static func recoverByQuarantining<Value: Sendable>(
        at url: URL,
        now: Date = Date(),
        beforePromotion: @escaping @Sendable () async throws -> Void = {},
        populate: @escaping @Sendable (DatabasePool) async throws -> Value
    ) async throws -> (result: ConfigurationDatabaseOpenResult, value: Value) {
        try await recoverByQuarantining(
            at: url,
            now: now,
            using: open,
            beforePromotion: beforePromotion,
            populate: populate
        )
    }

    static func recoverByQuarantining<Value: Sendable>(
        at url: URL,
        now: Date,
        using openDatabase: (URL) throws -> DatabasePool,
        beforePromotion: @escaping @Sendable () async throws -> Void = {},
        populate: @escaping @Sendable (DatabasePool) async throws -> Value
    ) async throws -> (result: ConfigurationDatabaseOpenResult, value: Value) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            throw ConfigurationDatabaseError.invalidDatabaseDirectory
        }
        try rejectUnsupportedSchemaIfPresent(at: url)
        let plan = try recoveryPlan(for: url, now: now)
        let staging = try openDatabase(plan.replacementURL)
        let value: Value
        do {
            value = try await populate(staging)
        } catch let preparationError {
            do {
                try staging.close()
            } catch {
                throw ConfigurationDatabaseError.recoveryPreparationCleanupFailed
            }
            throw preparationError
        }
        do {
            try staging.close()
        } catch {
            throw ConfigurationDatabaseError.recoveryPreparationCleanupFailed
        }
        do {
            try await beforePromotion()
        } catch let preparationError {
            do {
                try removeDatabaseFamilyIfPresent(at: plan.replacementURL)
            } catch {
                throw ConfigurationDatabaseError.recoveryPreparationCleanupFailed
            }
            throw preparationError
        }

        let originalItemCount = try moveDatabaseFamily(from: url, to: plan.originalURL)
        do {
            _ = try moveDatabaseFamily(from: plan.replacementURL, to: url)
        } catch let promotionError {
            try restoreOriginal(plan.originalURL, to: url)
            throw promotionError
        }

        do {
            let database = try openDatabase(url)
            return (
                ConfigurationDatabaseOpenResult(
                    database: database,
                    recovery: ConfigurationDatabaseRecovery(
                        quarantinedItemCount: originalItemCount,
                        occurredAt: now
                    )
                ),
                value
            )
        } catch let reopenError {
            do {
                _ = try moveDatabaseFamily(from: url, to: plan.replacementURL)
                try restoreOriginal(plan.originalURL, to: url)
            } catch {
                throw ConfigurationDatabaseError.recoveryRollbackFailed
            }
            throw reopenError
        }
    }

    public static func open(at url: URL) throws -> DatabasePool {
        try rejectUnsupportedSchemaIfPresent(at: url)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.maximumReaderCount = 4
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA foreign_keys = ON")
            try database.execute(sql: "PRAGMA journal_mode = WAL")
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        let databaseMigrator = migrator
        let isUnsupported = try pool.read { database in
            try databaseMigrator.hasBeenSuperseded(database)
        }
        guard !isUnsupported else {
            try pool.close()
            throw ConfigurationDatabaseError.unsupportedSchema
        }
        try databaseMigrator.migrate(pool)
        let integrity = try pool.read { database in
            try String.fetchOne(database, sql: "PRAGMA quick_check")
        }
        guard integrity == "ok" else { throw ConfigurationDatabaseError.integrityCheckFailed }
        try setOwnerOnlyPermissions(at: url)
        return pool
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("configuration-v1") { database in
            try database.create(table: "policy_metadata") { table in
                table.column("singleton_id", .integer).primaryKey().check { $0 == 1 }
                table.column("lineage_id", .text).notNull()
                table.column("authorized_uid", .integer).notNull()
                table.column("desired_generation", .integer).notNull()
                table.column("operation_mode", .text).notNull()
                table.column("active_profile_id", .text)
                table.column("modified_at", .double).notNull()
            }
            try database.create(table: "rules") { table in
                table.column("id", .text).primaryKey()
                table.column("encoded_rule", .blob).notNull()
                table.column("modified_at", .double).notNull()
            }
            try database.create(table: "enabled_local_groups") { table in
                table.column("id", .text).primaryKey()
            }
            try database.create(table: "policy_outbox") { table in
                table.column("generation", .integer).primaryKey()
                table.column("lineage_id", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("content_hash", .blob).notNull()
                table.column("artifact", .blob).notNull()
                table.column("state", .text).notNull()
                table.column("provider_epoch", .text)
                table.column("persisted_at", .double)
                table.column("enforced_at", .double)
            }
            try database.create(index: "policy_outbox_state", on: "policy_outbox", columns: ["state"])
            try database.create(table: "command_audit") { table in
                table.autoIncrementedPrimaryKey("sequence")
                table.column("generation", .integer).notNull()
                table.column("command_kind", .text).notNull()
                table.column("created_at", .double).notNull()
                table.column("redacted_summary", .text).notNull()
            }
            try database.create(table: "backup_runs") { table in
                table.column("day", .text).primaryKey()
                table.column("completed_at", .double).notNull()
                table.column("path", .text).notNull()
            }
        }
        migrator.registerMigration("configuration-v2-definitions") { database in
            try database.create(table: "local_group_definitions") { table in
                table.column("id", .text).primaryKey()
                table.column("encoded_value", .blob).notNull()
            }
            try database.create(table: "profile_definitions") { table in
                table.column("id", .text).primaryKey()
                table.column("encoded_value", .blob).notNull()
            }
            try database.create(table: "policy_preferences") { table in
                table.column("singleton_id", .integer).primaryKey().check { $0 == 1 }
                table.column("base_mode", .text).notNull()
            }
            try database.execute(sql: "INSERT INTO policy_preferences VALUES (1, 'silentAllow')")
        }
        migrator.registerMigration("configuration-v3-blocklist-sources") { database in
            try database.create(table: "blocklist_sources") { table in
                table.column("id", .text).primaryKey()
                table.column("encoded_value", .blob).notNull()
            }
        }
        migrator.registerMigration("configuration-v4-rule-usage") { database in
            try database.create(table: "rule_usage") { table in
                table.column("rule_id", .text).primaryKey()
                table.column("lower_bound_count", .integer).notNull()
                table.column("last_used_at", .double)
            }
            try database.create(table: "usage_coverage") { table in
                table.column("singleton_id", .integer).primaryKey().check { $0 == 1 }
                table.column("state", .text).notNull()
                table.column("provider_epoch", .text)
            }
            try database.execute(
                sql: "INSERT INTO usage_coverage VALUES (1, 'complete', NULL)"
            )
        }
        migrator.registerMigration("configuration-v5-restore-recovery") { database in
            try database.create(table: "restore_recovery") { table in
                table.column("singleton_id", .integer).primaryKey().check { $0 == 1 }
                table.column("backup_name", .text).notNull()
                table.column("target_generation", .integer).notNull()
                table.column("created_at", .double).notNull()
            }
        }
        migrator.registerMigration("configuration-v6-blocklist-entry-overrides") { database in
            try database.create(table: BlocklistOverrideStore.tableName) { table in
                table.column("entry_key", .text).primaryKey()
                table.column("encoded_value", .blob).notNull()
            }
        }
        return migrator
    }

    private static func setOwnerOnlyPermissions(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }

    static func moveDatabaseFamily(
        from sourceURL: URL,
        to destinationURL: URL,
        setPermissions: ((URL) throws -> Void)? = nil
    ) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sourceURL.path) else {
            throw ConfigurationDatabaseError.invalidDatabaseDirectory
        }
        let suffixes = ["", "-wal", "-shm"].filter {
            manager.fileExists(atPath: sourceURL.path + $0)
        }
        for suffix in suffixes where manager.fileExists(atPath: destinationURL.path + suffix) {
            throw CocoaError(.fileWriteFileExists)
        }
        let applyPermissions = setPermissions ?? { url in
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }

        var moved: [(source: URL, destination: URL)] = []
        do {
            for suffix in suffixes {
                let source = URL(fileURLWithPath: sourceURL.path + suffix)
                let destination = URL(fileURLWithPath: destinationURL.path + suffix)
                try manager.moveItem(at: source, to: destination)
                moved.append((source, destination))
                try applyPermissions(destination)
            }
            return moved.count
        } catch let moveError {
            var rollbackFailed = false
            for move in moved.reversed() {
                do {
                    try manager.moveItem(at: move.destination, to: move.source)
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed { throw ConfigurationDatabaseError.recoveryRollbackFailed }
            throw moveError
        }
    }

    private struct RecoveryPlan {
        let originalURL: URL
        let replacementURL: URL
    }

    private static func recoveryPlan(for url: URL, now: Date) throws -> RecoveryPlan {
        let manager = FileManager.default
        let quarantine = url.deletingLastPathComponent().appendingPathComponent(
            "Configuration Quarantine", isDirectory: true
        )
        try manager.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantine.path)
        let stem = "configuration-\(Int64(now.timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
        return RecoveryPlan(
            originalURL: quarantine.appendingPathComponent(stem + ".sqlite"),
            replacementURL: quarantine.appendingPathComponent(stem + "-replacement.sqlite")
        )
    }

    private static func restoreOriginal(_ originalURL: URL, to url: URL) throws {
        do {
            _ = try moveDatabaseFamily(from: originalURL, to: url)
        } catch {
            throw ConfigurationDatabaseError.recoveryRollbackFailed
        }
    }

    private static func removeDatabaseFamilyIfPresent(at url: URL) throws {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let member = URL(fileURLWithPath: url.path + suffix)
            if manager.fileExists(atPath: member.path) {
                try manager.removeItem(at: member)
            }
        }
    }

    private static func rejectUnsupportedSchemaIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let isUnsupported = try schemaSnapshotIsUnsupported(at: url)
            if isUnsupported { throw ConfigurationDatabaseError.unsupportedSchema }
        } catch {
            guard isRecoverableCorruption(error) else { throw error }
        }
    }

    private static func schemaSnapshotIsUnsupported(at url: URL) throws -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "abyss-configuration-preflight-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let snapshot = directory.appendingPathComponent("config.sqlite")
        let isUnsupported: Bool
        do {
            for suffix in ["", "-wal"] where manager.fileExists(atPath: url.path + suffix) {
                let source = URL(fileURLWithPath: url.path + suffix)
                let destination = URL(fileURLWithPath: snapshot.path + suffix)
                try manager.copyItem(at: source, to: destination)
                try manager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
            }
            var configuration = Configuration()
            configuration.readonly = true
            configuration.busyMode = .timeout(5)
            let database = try DatabaseQueue(path: snapshot.path, configuration: configuration)
            isUnsupported = try database.read { value in
                try migrator.hasBeenSuperseded(value)
            }
            try database.close()
        } catch let readError {
            do {
                try manager.removeItem(at: directory)
            } catch {
                throw ConfigurationDatabaseError.schemaPreflightCleanupFailed
            }
            throw readError
        }
        do {
            try manager.removeItem(at: directory)
        } catch {
            throw ConfigurationDatabaseError.schemaPreflightCleanupFailed
        }
        return isUnsupported
    }

    private static func isRecoverableCorruption(_ error: any Error) -> Bool {
        if let databaseError = error as? ConfigurationDatabaseError {
            return databaseError == .integrityCheckFailed
        }
        guard let databaseError = error as? DatabaseError else { return false }
        switch databaseError.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_FORMAT, .SQLITE_NOTADB:
            return true
        default:
            return false
        }
    }
}
