import AbyssCore
import Foundation
import GRDB

public enum GeoDatabaseError: Error, Sendable, Equatable {
    case databaseMissing
    case unsafeDatabaseFile
    case integrityCheckFailed
    case metadataMissing
    case invalidStoredLocation
}

public struct GeoLookupRequest: Sendable, Hashable {
    public let id: String
    public let endpoint: Endpoint?

    public init(id: String, endpoint: Endpoint?) {
        self.id = id
        self.endpoint = endpoint
    }
}

public enum GeoDatabase {
    public static func openExisting(at url: URL) throws -> GeoRepository {
        try GeoDatabasePromotion.recoverInterruptedPromotion(at: url)
        let result = try validatedDatabase(at: url)
        return GeoRepository(database: result.database, metadata: result.metadata)
    }

    static func validateExisting(at url: URL) throws -> GeoDatabaseMetadata {
        let result = try validatedDatabase(at: url)
        try result.database.close()
        return result.metadata
    }

    private static func validatedDatabase(
        at url: URL
    ) throws -> (database: DatabaseQueue, metadata: GeoDatabaseMetadata) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GeoDatabaseError.databaseMissing
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw GeoDatabaseError.unsafeDatabaseFile
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(3)
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        let result = try database.read { database -> (String, String, Date?, Date, Int) in
            let integrity = try String.fetchOne(database, sql: "PRAGMA quick_check")
            guard integrity == "ok" else { throw GeoDatabaseError.integrityCheckFailed }
            guard let row = try Row.fetchOne(database, sql: "SELECT * FROM geo_metadata WHERE singleton_id = 1") else {
                throw GeoDatabaseError.metadataMissing
            }
            let sourceModified: Double? = row["source_modified_at"]
            return (
                row["source_name"], row["source_version"],
                sourceModified.map(Date.init(timeIntervalSince1970:)),
                Date(timeIntervalSince1970: row["imported_at"]), row["record_count"]
            )
        }
        let metadata = GeoDatabaseMetadata(
            sourceName: result.0,
            sourceVersion: result.1,
            sourceModifiedAt: result.2,
            importedAt: result.3,
            recordCount: result.4
        )
        return (database, metadata)
    }

    static func createStaging(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.busyMode = .timeout(3)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = DELETE")
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        let database = try DatabaseQueue(path: url.path, configuration: configuration)
        try database.write { database in
            try database.create(table: "geo_ranges", options: [.withoutRowID]) { table in
                table.column("family", .integer).notNull()
                table.column("ip_start", .blob).notNull()
                table.column("ip_end", .blob).notNull()
                table.column("continent", .text).notNull()
                table.column("country", .text).notNull()
                table.column("region", .text).notNull()
                table.column("city", .text).notNull()
                table.column("latitude", .double).notNull()
                table.column("longitude", .double).notNull()
                table.primaryKey(["family", "ip_start"])
            }
            try database.create(table: "geo_metadata") { table in
                table.column("singleton_id", .integer).primaryKey().check { $0 == 1 }
                table.column("source_name", .text).notNull()
                table.column("source_version", .text).notNull()
                table.column("source_modified_at", .double)
                table.column("imported_at", .double).notNull()
                table.column("record_count", .integer).notNull()
            }
        }
        return database
    }
}

public actor GeoRepository {
    private let database: DatabaseQueue
    public nonisolated let metadata: GeoDatabaseMetadata

    init(database: DatabaseQueue, metadata: GeoDatabaseMetadata) {
        self.database = database
        self.metadata = metadata
    }

    public func resolve(_ requests: [GeoLookupRequest]) throws -> [String: GeoResolution] {
        let bounded = Array(requests.prefix(50_000))
        return try database.read { database in
            var results: [String: GeoResolution] = [:]
            var cache: [IPAddress: GeoResolution] = [:]
            for request in bounded {
                if let classified = GeoEndpointClassifier.nonGeographic(request.endpoint) {
                    results[request.id] = classified
                    continue
                }
                guard let address = request.endpoint?.address else {
                    results[request.id] = .nonGeographic(.missingEndpoint)
                    continue
                }
                if let cached = cache[address] {
                    results[request.id] = cached
                    continue
                }
                let resolution = try Self.lookup(address, in: database)
                cache[address] = resolution
                results[request.id] = resolution
            }
            return results
        }
    }

    private static func lookup(_ address: IPAddress, in database: Database) throws -> GeoResolution {
        let bytes = Data(address.bytes)
        guard let row = try Row.fetchOne(
            database,
            sql: """
                SELECT ip_end, continent, country, region, city, latitude, longitude
                FROM geo_ranges
                WHERE family = ? AND ip_start <= ?
                ORDER BY ip_start DESC
                LIMIT 1
                """,
            arguments: [Int(address.family.rawValue), bytes]
        ) else { return .notFound }
        let upper: Data = row["ip_end"]
        guard !upper.lexicographicallyPrecedes(bytes) else { return .notFound }
        do {
            return .located(try GeoLocation(
                continentCode: row["continent"],
                countryCode: row["country"],
                region: row["region"],
                city: row["city"],
                latitude: row["latitude"],
                longitude: row["longitude"]
            ))
        } catch {
            throw GeoDatabaseError.invalidStoredLocation
        }
    }
}
