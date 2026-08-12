import Foundation
import GRDB

public struct HistoryDatabaseRecovery: Sendable, Hashable {
    public let quarantinedItemCount: Int
    public let occurredAt: Date

    public init(quarantinedItemCount: Int, occurredAt: Date) {
        self.quarantinedItemCount = quarantinedItemCount
        self.occurredAt = occurredAt
    }
}

public struct HistoryDatabaseOpenResult: Sendable {
    public let database: DatabasePool
    public let recovery: HistoryDatabaseRecovery?

    public init(database: DatabasePool, recovery: HistoryDatabaseRecovery?) {
        self.database = database
        self.recovery = recovery
    }
}

public enum HistoryDatabase {
    public static func openRecovering(at url: URL, now: Date = Date()) throws -> HistoryDatabaseOpenResult {
        try openRecovering(at: url, now: now, using: open)
    }

    static func openRecovering(
        at url: URL,
        now: Date,
        using openDatabase: (URL) throws -> DatabasePool
    ) throws -> HistoryDatabaseOpenResult {
        do {
            return HistoryDatabaseOpenResult(database: try openDatabase(url), recovery: nil)
        } catch let initialError {
            guard isRecoverableCorruption(initialError),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw initialError
            }

            let quarantined = try quarantineDatabase(at: url, now: now)
            do {
                let replacement = try openDatabase(quarantined.replacementURL)
                try replacement.close()
            } catch let replacementError {
                try restoreOriginal(quarantined, to: url)
                throw replacementError
            }

            do {
                _ = try moveDatabaseFamily(from: quarantined.replacementURL, to: url)
            } catch let promotionError {
                try restoreOriginal(quarantined, to: url)
                throw promotionError
            }

            do {
                return HistoryDatabaseOpenResult(
                    database: try openDatabase(url),
                    recovery: HistoryDatabaseRecovery(
                        quarantinedItemCount: quarantined.itemCount,
                        occurredAt: now
                    )
                )
            } catch let reopenError {
                do {
                    _ = try moveDatabaseFamily(from: url, to: quarantined.replacementURL)
                    try restoreOriginal(quarantined, to: url)
                } catch {
                    throw HistoryDatabaseError.recoveryRollbackFailed
                }
                throw reopenError
            }
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
        configuration.busyMode = .timeout(3)
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
        guard !isUnsupported else { throw HistoryDatabaseError.unsupportedSchema }
        try databaseMigrator.migrate(pool)
        let integrity = try pool.read { database in
            try String.fetchOne(database, sql: "PRAGMA quick_check")
        }
        guard integrity == "ok" else { throw HistoryDatabaseError.integrityCheckFailed }
        try setOwnerOnlyPermissions(at: url)
        return pool
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("history-v1") { database in
            try database.create(table: "history_settings") { table in
                table.column("singleton_id", .integer).primaryKey().check { $0 == 1 }
                table.column("enabled", .boolean).notNull()
                table.column("retention_days", .integer).notNull()
                table.column("maximum_flows", .integer).notNull()
            }
            try database.execute(
                sql: "INSERT INTO history_settings VALUES (1, 1, 30, 50000)"
            )
            try database.create(table: "flow_events") { table in
                table.column("provider_epoch", .text).notNull()
                table.column("sequence", .integer).notNull()
                table.column("occurred_at", .double).notNull()
                table.column("flow_id", .text).notNull()
                table.column("encoded_event", .blob).notNull()
                table.primaryKey(["provider_epoch", "sequence"])
            }
            try database.create(
                index: "flow_events_time",
                on: "flow_events",
                columns: ["occurred_at"]
            )
            try database.create(table: "coverage_gaps") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("provider_epoch", .text)
                table.column("observed_at", .double).notNull()
                table.column("reason", .text).notNull()
                table.column("dropped_count", .integer).notNull()
                table.uniqueKey(["provider_epoch", "reason", "dropped_count"])
            }
        }
        migrator.registerMigration("history-v2-flow-lifecycle") { database in
            try database.alter(table: "flow_events") { table in
                table.add(column: "event_kind", .text).notNull().defaults(to: "decision")
            }
            try database.create(
                index: "flow_events_kind_time",
                on: "flow_events",
                columns: ["event_kind", "occurred_at"]
            )
            try database.create(table: "flow_lifecycle") { table in
                table.column("provider_epoch", .text).notNull()
                table.column("flow_id", .text).notNull()
                table.column("decision_sequence", .integer)
                table.column("decision_at", .double)
                table.column("decision_event", .blob)
                table.column("closed_at", .double)
                table.column("bytes_inbound", .integer)
                table.column("bytes_outbound", .integer)
                table.column("flow_end_reason", .text)
                table.primaryKey(["provider_epoch", "flow_id"])
            }
            try database.create(
                index: "flow_lifecycle_decision_time",
                on: "flow_lifecycle",
                columns: ["decision_at"]
            )
            try database.execute(sql: """
                INSERT OR IGNORE INTO flow_lifecycle
                    (provider_epoch, flow_id, decision_sequence, decision_at, decision_event)
                SELECT provider_epoch, flow_id, sequence, occurred_at, encoded_event
                FROM flow_events
                WHERE event_kind = 'decision'
                """)
        }
        migrator.registerMigration("history-v3-page-order") { database in
            try database.execute(sql: """
                CREATE INDEX flow_lifecycle_page_order
                ON flow_lifecycle(
                    decision_at DESC, decision_sequence DESC,
                    provider_epoch DESC, flow_id DESC
                )
                """)
            try database.create(
                index: "coverage_gaps_observed_at",
                on: "coverage_gaps",
                columns: ["observed_at"]
            )
        }
        migrator.registerMigration("history-v4-coverage-intervals") { database in
            try database.alter(table: "coverage_gaps") { table in
                table.add(column: "started_at", .double)
                table.add(column: "ended_at", .double)
                table.add(column: "reason_code", .text)
                table.add(column: "source_id", .text)
            }
            try database.execute(sql: """
                UPDATE coverage_gaps
                SET started_at = observed_at,
                    ended_at = observed_at,
                    reason_code = CASE
                        WHEN reason LIKE 'extensionRingOverflow%' THEN 'extensionRingOverflow'
                        ELSE 'legacyUnknown'
                    END,
                    source_id = CASE
                        WHEN instr(reason, ':') > 0
                        THEN substr(reason, instr(reason, ':') + 1)
                        ELSE NULL
                    END
                """)
            try database.create(
                index: "coverage_gaps_range",
                on: "coverage_gaps",
                columns: ["started_at", "ended_at"]
            )
            try database.create(table: "history_coverage_state") { table in
                table.column("singleton_id", .integer).primaryKey().check { $0 == 1 }
                table.column("recording_since", .double)
                table.column("disabled_since", .double)
            }
            let earliestEvent = try Double.fetchOne(
                database,
                sql: "SELECT MIN(occurred_at) FROM flow_events"
            )
            let historyEnabled = try Bool.fetchOne(
                database,
                sql: "SELECT enabled FROM history_settings WHERE singleton_id = 1"
            ) ?? true
            let migratedAt = Date().timeIntervalSince1970
            try database.execute(
                sql: "INSERT INTO history_coverage_state VALUES (1, ?, ?)",
                arguments: [earliestEvent ?? migratedAt, historyEnabled ? nil : migratedAt]
            )
        }
        migrator.registerMigration("history-v5-runtime-instance-coverage") { database in
            try database.alter(table: "history_coverage_state") { table in
                table.add(column: "last_runtime_instance_id", .text)
                table.add(column: "last_successful_drain_at", .double)
            }
        }
        return migrator
    }

    private static func rejectUnsupportedSchemaIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let isUnsupported = try schemaSnapshotIsUnsupported(at: url)
            if isUnsupported { throw HistoryDatabaseError.unsupportedSchema }
        } catch {
            guard isRecoverableCorruption(error) else { throw error }
        }
    }

    private static func schemaSnapshotIsUnsupported(at url: URL) throws -> Bool {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "abyss-history-preflight-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let snapshot = directory.appendingPathComponent("history.sqlite")
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
            configuration.busyMode = .timeout(3)
            let database = try DatabaseQueue(path: snapshot.path, configuration: configuration)
            isUnsupported = try database.read { value in
                try migrator.hasBeenSuperseded(value)
            }
            try database.close()
        } catch let readError {
            do {
                try manager.removeItem(at: directory)
            } catch {
                throw HistoryDatabaseError.schemaPreflightCleanupFailed
            }
            throw readError
        }
        do {
            try manager.removeItem(at: directory)
        } catch {
            throw HistoryDatabaseError.schemaPreflightCleanupFailed
        }
        return isUnsupported
    }

    static func isRecoverableCorruption(_ error: any Error) -> Bool {
        if let historyError = error as? HistoryDatabaseError {
            return historyError == .integrityCheckFailed
        }
        guard let databaseError = error as? DatabaseError else { return false }
        switch databaseError.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_FORMAT, .SQLITE_NOTADB:
            return true
        default:
            return false
        }
    }

    private struct QuarantinedDatabase {
        let originalURL: URL
        let replacementURL: URL
        let itemCount: Int
    }

    private static func quarantineDatabase(at url: URL, now: Date) throws -> QuarantinedDatabase {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent().appendingPathComponent(
            "History Quarantine", isDirectory: true
        )
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let stem = "history-\(Int64(now.timeIntervalSince1970))-\(UUID().uuidString.lowercased())"
        let originalURL = directory.appendingPathComponent(stem + ".sqlite")
        let replacementURL = directory.appendingPathComponent(stem + "-replacement.sqlite")
        return QuarantinedDatabase(
            originalURL: originalURL,
            replacementURL: replacementURL,
            itemCount: try moveDatabaseFamily(from: url, to: originalURL)
        )
    }

    private static func restoreOriginal(
        _ quarantined: QuarantinedDatabase,
        to url: URL
    ) throws {
        do {
            _ = try moveDatabaseFamily(from: quarantined.originalURL, to: url)
        } catch {
            throw HistoryDatabaseError.recoveryRollbackFailed
        }
    }

    private static func moveDatabaseFamily(from sourceURL: URL, to destinationURL: URL) throws -> Int {
        let manager = FileManager.default
        let suffixes = ["", "-wal", "-shm"].filter { suffix in
            manager.fileExists(atPath: sourceURL.path + suffix)
        }
        for suffix in suffixes where manager.fileExists(atPath: destinationURL.path + suffix) {
            throw CocoaError(.fileWriteFileExists)
        }

        var moved: [(source: URL, destination: URL)] = []
        do {
            for suffix in suffixes {
                let source = URL(fileURLWithPath: sourceURL.path + suffix)
                let destination = URL(fileURLWithPath: destinationURL.path + suffix)
                try manager.moveItem(at: source, to: destination)
                moved.append((source, destination))
                try manager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
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
            if rollbackFailed { throw HistoryDatabaseError.recoveryRollbackFailed }
            throw moveError
        }
    }

    private static func setOwnerOnlyPermissions(at url: URL) throws {
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }
}

public enum HistoryDatabaseError: Error, Sendable, Equatable {
    case integrityCheckFailed
    case unsupportedSchema
    case schemaPreflightCleanupFailed
    case recoveryRollbackFailed
}
