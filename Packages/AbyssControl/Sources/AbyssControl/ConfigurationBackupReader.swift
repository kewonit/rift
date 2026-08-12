import AbyssCore
import AbyssIPC
import Darwin
import Foundation
import GRDB
import SQLite3

public enum ConfigurationBackupReaderError: Error, Sendable, Equatable {
    case invalidFile
    case wrongOwner
    case unsafePermissions
    case resourceLimitExceeded
    case fileChangedWhileReading
    case integrityCheckFailed
}

struct ConfigurationBackupReadLimits: Sendable {
    let maximumFileBytes: Int
    let maximumPageCount: Int
    let minimumPageBytes: Int
    let maximumPageBytes: Int
    let maximumRuleEncodedBytes: Int
    let maximumAggregateEncodedBytes: Int
    let expectedOwner: uid_t

    static let production = ConfigurationBackupReadLimits(
        maximumFileBytes: 8 * IPCProtocolLimits.maximumSnapshotBytes,
        maximumPageCount: 8 * IPCProtocolLimits.maximumSnapshotBytes / 512,
        minimumPageBytes: 512,
        maximumPageBytes: 65_536,
        maximumRuleEncodedBytes: IPCProtocolLimits.maximumSnapshotBytes,
        maximumAggregateEncodedBytes: 4 * IPCProtocolLimits.maximumSnapshotBytes,
        expectedOwner: geteuid()
    )
}

public enum ConfigurationBackupReader {
    public static func read(_ url: URL) throws -> PolicyConfigurationDraft? {
        try read(url, limits: .production)
    }

    static func read(
        _ url: URL,
        limits: ConfigurationBackupReadLimits,
        afterSnapshotRead: () throws -> Void = {}
    ) throws -> PolicyConfigurationDraft? {
        try withSnapshot(
            at: url,
            limits: limits,
            afterSnapshotRead: afterSnapshotRead
        ) { storage, byteCount, storageTransferred in
            try decode(
                storage: storage,
                byteCount: byteCount,
                limits: limits,
                storageTransferred: &storageTransferred
            )
        }
    }

    private static func decode(
        storage: UnsafeMutableRawPointer,
        byteCount: Int,
        limits: ConfigurationBackupReadLimits,
        storageTransferred: inout Bool
    ) throws -> PolicyConfigurationDraft? {
        let bytes = storage.bindMemory(to: UInt8.self, capacity: byteCount)
        let signature = Array("SQLite format 3\0".utf8)
        guard byteCount >= 100,
              signature.indices.allSatisfy({ bytes[$0] == signature[$0] }),
              (bytes[18] == 1 || bytes[18] == 2),
              (bytes[19] == 1 || bytes[19] == 2) else {
            throw ConfigurationBackupReaderError.integrityCheckFailed
        }
        // Online backups may retain WAL header flags. This detached copy has no WAL,
        // so use SQLite's documented rollback-mode header for deserialization only.
        bytes[18] = 1
        bytes[19] = 1

        let queue = try DatabaseQueue()
        defer { try? queue.close() }
        let result = queue.writeWithoutTransaction { database in
            guard let connection = database.sqliteConnection else { return SQLITE_MISUSE }
            storageTransferred = true
            return sqlite3_deserialize(
                connection,
                "main",
                bytes,
                sqlite3_int64(byteCount),
                sqlite3_int64(byteCount),
                UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_READONLY)
            )
        }
        guard result == SQLITE_OK else {
            throw ConfigurationBackupReaderError.integrityCheckFailed
        }
        try queue.read { database in
            try validateLayout(database, byteCount: byteCount, limits: limits)
        }
        let integrity = try queue.read { database in
            try String.fetchOne(database, sql: "PRAGMA quick_check")
        }
        guard integrity == "ok" else {
            throw ConfigurationBackupReaderError.integrityCheckFailed
        }
        return try queue.read { database in
            try PolicyConfigurationReader.read(
                database,
                maximumRuleEncodedBytes: limits.maximumRuleEncodedBytes,
                maximumAggregateEncodedBytes: limits.maximumAggregateEncodedBytes
            )
        }
    }

    private static func validateLayout(
        _ database: Database,
        byteCount: Int,
        limits: ConfigurationBackupReadLimits
    ) throws {
        let pageSize = try Int.fetchOne(database, sql: "PRAGMA page_size") ?? 0
        let pageCount = try Int.fetchOne(database, sql: "PRAGMA page_count") ?? 0
        guard pageSize >= limits.minimumPageBytes,
              pageSize <= limits.maximumPageBytes,
              pageSize.nonzeroBitCount == 1,
              pageCount > 0,
              pageCount <= limits.maximumPageCount else {
            throw ConfigurationBackupReaderError.resourceLimitExceeded
        }
        let product = pageSize.multipliedReportingOverflow(by: pageCount)
        guard !product.overflow, product.partialValue <= limits.maximumFileBytes else {
            throw ConfigurationBackupReaderError.resourceLimitExceeded
        }
        guard product.partialValue == byteCount else {
            throw ConfigurationBackupReaderError.integrityCheckFailed
        }
    }

    private static func withSnapshot<Value>(
        at url: URL,
        limits: ConfigurationBackupReadLimits,
        afterSnapshotRead: () throws -> Void,
        body: (UnsafeMutableRawPointer, Int, inout Bool) throws -> Value
    ) throws -> Value {
        guard url.isFileURL, url.path.hasPrefix("/"),
              !url.path.utf8.contains(0), url.path.utf8.count < Int(PATH_MAX),
              limits.maximumFileBytes > 0 else {
            throw ConfigurationBackupReaderError.invalidFile
        }
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw ConfigurationBackupReaderError.invalidFile }
        defer { Darwin.close(descriptor) }

        let original = try descriptorStatus(descriptor)
        guard original.st_mode & S_IFMT == S_IFREG else {
            throw ConfigurationBackupReaderError.invalidFile
        }
        guard original.st_uid == limits.expectedOwner else {
            throw ConfigurationBackupReaderError.wrongOwner
        }
        guard original.st_mode & 0o077 == 0 else {
            throw ConfigurationBackupReaderError.unsafePermissions
        }
        var fileSystem = statfs()
        guard fstatfs(descriptor, &fileSystem) == 0,
              fileSystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw ConfigurationBackupReaderError.invalidFile
        }
        guard let initialPath = pathStatus(url.path), sameSnapshot(original, initialPath) else {
            throw ConfigurationBackupReaderError.fileChangedWhileReading
        }
        guard original.st_size > 0,
              UInt64(original.st_size) <= UInt64(limits.maximumFileBytes),
              UInt64(original.st_size) <= UInt64(Int.max) else {
            throw ConfigurationBackupReaderError.resourceLimitExceeded
        }

        let byteCount = Int(original.st_size)
        guard let storage = sqlite3_malloc64(sqlite3_uint64(byteCount)) else {
            throw ConfigurationBackupReaderError.resourceLimitExceeded
        }
        var storageTransferred = false
        defer {
            if !storageTransferred { sqlite3_free(storage) }
        }
        var offset = 0
        while offset < byteCount {
            let amount = Darwin.read(
                descriptor,
                storage.advanced(by: offset),
                byteCount - offset
            )
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else {
                throw ConfigurationBackupReaderError.fileChangedWhileReading
            }
            offset += amount
        }

        try afterSnapshotRead()
        let current = try descriptorStatus(descriptor)
        guard let currentPath = pathStatus(url.path),
              sameSnapshot(original, current),
              sameSnapshot(original, currentPath) else {
            throw ConfigurationBackupReaderError.fileChangedWhileReading
        }
        return try body(storage, byteCount, &storageTransferred)
    }

    private static func descriptorStatus(_ descriptor: Int32) throws -> stat {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw ConfigurationBackupReaderError.invalidFile
        }
        return value
    }

    private static func pathStatus(_ path: String) -> stat? {
        var value = stat()
        return lstat(path, &value) == 0 ? value : nil
    }

    private static func sameSnapshot(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

enum PolicyConfigurationReader {
    static func read(_ database: Database) throws -> PolicyConfigurationDraft? {
        try read(
            database,
            maximumRuleEncodedBytes: nil,
            maximumAggregateEncodedBytes: nil
        )
    }

    static func read(
        _ database: Database,
        maximumRuleEncodedBytes: Int?,
        maximumAggregateEncodedBytes: Int?
    ) throws -> PolicyConfigurationDraft? {
        guard let metadata = try Row.fetchOne(
            database,
            sql: "SELECT * FROM policy_metadata WHERE singleton_id = 1"
        ) else { return nil }
        let lineageValue: String = metadata["lineage_id"]
        let ownerValue: Int64 = metadata["authorized_uid"]
        let generationValue: Int64 = metadata["desired_generation"]
        let modeValue: String = metadata["operation_mode"]
        let profileValue: String? = metadata["active_profile_id"]
        guard let lineageID = UUID(uuidString: lineageValue),
              ownerValue >= 0, ownerValue <= Int64(UInt32.max),
              generationValue >= 0,
              let operationMode = OperationMode(rawValue: modeValue) else {
            throw PolicyRepositoryError.acknowledgementMismatch
        }
        let activeProfileID: UUID?
        if let profileValue {
            guard let value = UUID(uuidString: profileValue) else {
                throw PolicyRepositoryError.acknowledgementMismatch
            }
            activeProfileID = value
        } else {
            activeProfileID = nil
        }
        let decoder = CanonicalPolicyJSON.decoder()
        try validateAllBounds(
            database,
            maximumRuleEncodedBytes: maximumRuleEncodedBytes,
            maximumAggregateEncodedBytes: maximumAggregateEncodedBytes
        )
        let rules = try Row.fetchAll(
            database,
            sql: "SELECT id, encoded_rule FROM rules ORDER BY id"
        ).map { row in
            let storedID: String = row["id"]
            let rule = try decoder.decode(Rule.self, from: row["encoded_rule"] as Data)
            guard storedID == rule.id.uuidString.lowercased() else {
                throw PolicyRepositoryError.acknowledgementMismatch
            }
            return rule
        }
        let enabledGroups = try Set(Row.fetchAll(
            database,
            sql: "SELECT id FROM enabled_local_groups ORDER BY id"
        ).map { row -> UUID in
            let value: String = row["id"]
            guard let id = UUID(uuidString: value) else {
                throw PolicyRepositoryError.acknowledgementMismatch
            }
            return id
        })
        let localGroups = try decoded(
            LocalRuleGroup.self,
            table: "local_group_definitions",
            database: database,
            decoder: decoder
        )
        let profiles = try decoded(
            PolicyProfile.self,
            table: "profile_definitions",
            database: database,
            decoder: decoder
        )
        let blocklists = try decoded(
            BlocklistSource.self,
            table: "blocklist_sources",
            database: database,
            decoder: decoder
        )
        let disabledBlocklistEntries = try BlocklistOverrideStore.read(database, decoder: decoder)
        let baseValue = try String.fetchOne(
            database,
            sql: "SELECT base_mode FROM policy_preferences WHERE singleton_id = 1"
        )
        guard let baseValue, let baseMode = OperationMode(rawValue: baseValue) else {
            throw PolicyRepositoryError.acknowledgementMismatch
        }
        let draft = PolicyConfigurationDraft(
            lineageID: lineageID,
            authorizedUID: UInt32(ownerValue),
            operationMode: operationMode,
            baseOperationMode: baseMode,
            activeProfileID: activeProfileID,
            enabledLocalGroupIDs: enabledGroups,
            rules: rules,
            localGroups: localGroups,
            profiles: profiles,
            blocklists: blocklists,
            disabledBlocklistEntries: disabledBlocklistEntries
        )
        try PolicyConfigurationValidator.validate(draft)
        return draft
    }

    private static func decoded<Value: Decodable & Identifiable>(
        _ type: Value.Type,
        table: String,
        database: Database,
        decoder: JSONDecoder
    ) throws -> [Value] where Value.ID == UUID {
        guard ["local_group_definitions", "profile_definitions", "blocklist_sources"]
            .contains(table) else { throw PolicyRepositoryError.acknowledgementMismatch }
        return try Row.fetchAll(
            database,
            sql: "SELECT id, encoded_value FROM \(table) ORDER BY id"
        ).map { row in
            let storedID: String = row["id"]
            let value = try decoder.decode(Value.self, from: row["encoded_value"] as Data)
            guard storedID == value.id.uuidString.lowercased() else {
                throw PolicyRepositoryError.acknowledgementMismatch
            }
            return value
        }
    }

    private static func validateAllBounds(
        _ database: Database,
        maximumRuleEncodedBytes: Int?,
        maximumAggregateEncodedBytes: Int?
    ) throws {
        try validateBounds(
            table: "rules", blobColumn: "encoded_rule",
            maximumCount: PolicyConfigurationValidator.maximumRules,
            database: database
        )
        try validateBounds(
            table: "enabled_local_groups", blobColumn: nil,
            maximumCount: PolicyConfigurationValidator.maximumDefinitions,
            database: database
        )
        for table in ["local_group_definitions", "profile_definitions", "blocklist_sources"] {
            try validateBounds(
                table: table, blobColumn: "encoded_value",
                maximumCount: PolicyConfigurationValidator.maximumDefinitions,
                database: database
            )
        }
        guard maximumRuleEncodedBytes != nil || maximumAggregateEncodedBytes != nil else { return }
        guard let row = try Row.fetchOne(database, sql: """
            SELECT
                COALESCE((SELECT SUM(length(encoded_rule)) FROM rules), 0) AS rule_bytes,
                COALESCE((SELECT SUM(length(encoded_value)) FROM local_group_definitions), 0)
                    + COALESCE((SELECT SUM(length(encoded_value)) FROM profile_definitions), 0)
                    + COALESCE((SELECT SUM(length(encoded_value)) FROM blocklist_sources), 0)
                    AS definition_bytes
            """) else {
            throw PolicyConfigurationValidationError.excessiveCount
        }
        let ruleBytes: Int64 = row["rule_bytes"]
        let definitionBytes: Int64 = row["definition_bytes"]
        let overrideBytes = try BlocklistOverrideStore.encodedByteCount(database)
        guard ruleBytes >= 0, definitionBytes >= 0, overrideBytes >= 0 else {
            throw PolicyConfigurationValidationError.excessiveCount
        }
        if let maximumRuleEncodedBytes {
            guard maximumRuleEncodedBytes >= 0,
                  UInt64(ruleBytes) <= UInt64(maximumRuleEncodedBytes) else {
                throw ConfigurationBackupReaderError.resourceLimitExceeded
            }
        }
        if let maximumAggregateEncodedBytes {
            let definitions = definitionBytes.addingReportingOverflow(overrideBytes)
            let total = ruleBytes.addingReportingOverflow(definitions.partialValue)
            guard maximumAggregateEncodedBytes >= 0, !definitions.overflow, !total.overflow,
                  UInt64(total.partialValue) <= UInt64(maximumAggregateEncodedBytes) else {
                throw ConfigurationBackupReaderError.resourceLimitExceeded
            }
        }
    }

    private static func validateBounds(
        table: String,
        blobColumn: String?,
        maximumCount: Int,
        database: Database
    ) throws {
        let allowedTables = Set([
            "rules", "enabled_local_groups", "local_group_definitions",
            "profile_definitions", "blocklist_sources",
        ])
        guard allowedTables.contains(table),
              blobColumn == nil || blobColumn == "encoded_rule" || blobColumn == "encoded_value" else {
            throw PolicyRepositoryError.acknowledgementMismatch
        }
        let count = try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        guard count <= maximumCount else {
            throw PolicyConfigurationValidationError.excessiveCount
        }
        if let blobColumn {
            let maximum = try Int.fetchOne(
                database,
                sql: "SELECT COALESCE(MAX(length(\(blobColumn))), 0) FROM \(table)"
            ) ?? 0
            guard maximum <= PolicyConfigurationValidator.maximumEncodedRowBytes else {
                throw PolicyConfigurationValidationError.excessiveCount
            }
        }
    }
}
