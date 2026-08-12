import AbyssCore
import Foundation
import GRDB

enum BlocklistOverrideStore {
    static let tableName = "blocklist_disabled_entries"

    static func replace(_ database: Database, entries: Set<BlocklistEntry>) throws {
        try database.execute(sql: "DELETE FROM \(tableName)")
        let encoder = CanonicalPolicyJSON.encoder()
        for entry in entries.sorted() {
            try database.execute(
                sql: "INSERT INTO \(tableName) (entry_key, encoded_value) VALUES (?, ?)",
                arguments: [entry.storageKey, try encoder.encode(entry)]
            )
        }
    }

    static func read(_ database: Database, decoder: JSONDecoder) throws -> Set<BlocklistEntry> {
        guard try database.tableExists(tableName) else { return [] }
        let rows = try Row.fetchAll(
            database,
            sql: "SELECT entry_key, encoded_value FROM \(tableName) ORDER BY entry_key"
        )
        guard rows.count <= BlocklistEntryOverrides.maximumDisabledEntries else {
            throw PolicyConfigurationValidationError.excessiveCount
        }
        var entries: Set<BlocklistEntry> = []
        let encoder = CanonicalPolicyJSON.encoder()
        for row in rows {
            let key: String = row["entry_key"]
            let bytes: Data = row["encoded_value"]
            guard bytes.count <= PolicyConfigurationValidator.maximumEncodedRowBytes else {
                throw PolicyConfigurationValidationError.excessiveCount
            }
            let entry = try decoder.decode(BlocklistEntry.self, from: bytes)
            guard key == entry.storageKey,
                  try encoder.encode(entry) == bytes,
                  entries.insert(entry).inserted else {
                throw PolicyRepositoryError.acknowledgementMismatch
            }
        }
        return entries
    }

    static func encodedByteCount(_ database: Database) throws -> Int64 {
        guard try database.tableExists(tableName) else { return 0 }
        return try Int64.fetchOne(
            database,
            sql: "SELECT COALESCE(SUM(length(encoded_value)), 0) FROM \(tableName)"
        ) ?? 0
    }
}

private extension BlocklistEntry {
    var storageKey: String {
        switch self {
        case .domain(let value): "domain:\(value.ascii)"
        case .address(let value): "address:\(value.description)"
        }
    }
}
