import AbyssCore
import Foundation
import GRDB
import SQLite3
import Testing
@testable import AbyssControl

@Test func geoCSVImportBoundsCoverCurrentOfficialLiteDataset() {
    #expect(GeoCSVImporter.maximumFileBytes >= 673_700_000)
    #expect(GeoCSVImporter.maximumRecords >= 7_926_653)
}

@Test func geoCSVImportLooksUpIPv4IPv6AndKeepsExplicitUnknowns() async throws {
    try await withGeoTestDirectory { directory in
        let source = directory.appendingPathComponent("dbip-city-lite-2026-08.csv")
        let destination = directory.appendingPathComponent("geolocation.sqlite")
        let csv = """
            8.8.8.0,8.8.8.255,NA,US,California,"Mountain View",37.4229,-122.085
            2001:4860::,2001:4860:ffff:ffff:ffff:ffff:ffff:ffff,NA,US,California,"Mountain View",37.4229,-122.085
            """
        try Data(csv.utf8).write(to: source)
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = try GeoCSVImporter.importFile(
            from: source,
            to: destination,
            sourceVersion: "2026-08",
            sourceModifiedAt: nil,
            importedAt: importedAt
        )
        #expect(metadata.recordCount == 2)
        #expect(metadata.sourceVersion == "2026-08")

        let repository = try GeoDatabase.openExisting(at: destination)
        let results = try await repository.resolve([
            GeoLookupRequest(id: "v4", endpoint: try endpoint("8.8.8.8")),
            GeoLookupRequest(id: "v6", endpoint: try endpoint("2001:4860::8888")),
            GeoLookupRequest(id: "unknown", endpoint: try endpoint("1.1.1.1")),
            GeoLookupRequest(id: "local", endpoint: try endpoint(
                "10.0.0.4", classes: [.localNetwork]
            )),
            GeoLookupRequest(id: "missing", endpoint: nil),
        ])
        #expect(results["v4"]?.location?.city == "Mountain View")
        #expect(results["v6"]?.location?.countryCode == "US")
        #expect(results["unknown"] == .notFound)
        #expect(results["local"] == .nonGeographic(.localNetwork))
        #expect(results["missing"] == .nonGeographic(.missingEndpoint))
    }
}

@Test func failedGeoCSVImportRetainsLastKnownGoodDatabase() async throws {
    try await withGeoTestDirectory { directory in
        let source = directory.appendingPathComponent("dbip-city-lite-good.csv")
        let destination = directory.appendingPathComponent("geolocation.sqlite")
        try Data("8.8.8.0,8.8.8.255,NA,US,California,Mountain View,37.4,-122.1\n".utf8)
            .write(to: source)
        _ = try GeoCSVImporter.importFile(
            from: source,
            to: destination,
            sourceVersion: "good",
            sourceModifiedAt: nil
        )

        let broken = directory.appendingPathComponent("dbip-city-lite-broken.csv")
        let overlapping = """
            8.8.8.0,8.8.8.255,NA,US,California,Mountain View,37.4,-122.1
            8.8.8.128,8.8.9.0,NA,US,California,Mountain View,37.4,-122.1
            """
        try Data(overlapping.utf8).write(to: broken)
        #expect(throws: GeoCSVImportError.overlappingRanges(line: 2)) {
            try GeoCSVImporter.importFile(
                from: broken,
                to: destination,
                sourceVersion: "broken",
                sourceModifiedAt: nil
            )
        }

        let repository = try GeoDatabase.openExisting(at: destination)
        let result = try await repository.resolve([
            GeoLookupRequest(id: "retained", endpoint: try endpoint("8.8.8.8")),
        ])
        #expect(result["retained"]?.location?.countryCode == "US")
        #expect(repository.metadata.sourceVersion == "good")
    }
}

@Test(arguments: GeoDatabasePromotionCheckpoint.allCases)
func geoPromotionFailureRestoresCompleteLastKnownGoodFamily(
    _ checkpoint: GeoDatabasePromotionCheckpoint
) async throws {
    try await withGeoTestDirectory { directory in
        let destination = directory.appendingPathComponent("geolocation.sqlite")
        let oldSource = directory.appendingPathComponent("dbip-city-lite-old.csv")
        try Data("8.8.8.0,8.8.8.255,NA,US,California,Old City,37.4,-122.1\n".utf8)
            .write(to: oldSource)
        _ = try GeoCSVImporter.importFile(
            from: oldSource,
            to: destination,
            sourceVersion: "old",
            sourceModifiedAt: nil,
            importedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try preparePersistentGeoDatabaseWALFamily(at: destination)
        let beforeSuffixes = geoDatabaseFamilySuffixes(at: destination)
        try #require(beforeSuffixes.contains("-wal"))
        try #require(beforeSuffixes.contains("-shm"))

        let replacement = directory.appendingPathComponent("dbip-city-lite-new.csv")
        try Data("1.1.1.0,1.1.1.255,OC,AU,Queensland,New City,-27.4,153.0\n".utf8)
            .write(to: replacement)
        do {
            _ = try GeoCSVImporter.importFile(
                from: replacement,
                to: destination,
                sourceVersion: "new",
                sourceModifiedAt: nil,
                importedAt: Date(timeIntervalSince1970: 1_700_000_100),
                promotionFaultInjector: { reached in
                    if reached == checkpoint {
                        throw GeoPromotionTestError.injected(checkpoint)
                    }
                }
            )
            Issue.record("Expected the promotion fault to be injected")
        } catch let error as GeoPromotionTestError {
            #expect(error == .injected(checkpoint))
        }

        #expect(geoDatabaseFamilySuffixes(at: destination) == beforeSuffixes)
        #expect(geoDatabaseFamilySuffixes(at: geoPredecessorURL(for: destination)).isEmpty)
        let repository = try GeoDatabase.openExisting(at: destination)
        #expect(repository.metadata.sourceVersion == "old-wal")
        let resolved = try await repository.resolve([
            GeoLookupRequest(id: "old", endpoint: try endpoint("8.8.8.8")),
            GeoLookupRequest(id: "new", endpoint: try endpoint("1.1.1.1")),
        ])
        #expect(resolved["old"]?.location?.city == "Old City")
        #expect(resolved["new"] == .notFound)
    }
}

@Test func geoDatabaseOpenCompletesInterruptedValidPromotion() throws {
    try withGeoTestDirectory { directory in
        let destination = directory.appendingPathComponent("geolocation.sqlite")
        let replacement = directory.appendingPathComponent("replacement.sqlite")
        let oldSource = directory.appendingPathComponent("dbip-city-lite-old.csv")
        let newSource = directory.appendingPathComponent("dbip-city-lite-new.csv")
        try Data("8.8.8.0,8.8.8.255,NA,US,California,Old City,37.4,-122.1\n".utf8)
            .write(to: oldSource)
        try Data("1.1.1.0,1.1.1.255,OC,AU,Queensland,New City,-27.4,153.0\n".utf8)
            .write(to: newSource)
        _ = try GeoCSVImporter.importFile(
            from: oldSource, to: destination, sourceVersion: "old", sourceModifiedAt: nil
        )
        _ = try GeoCSVImporter.importFile(
            from: newSource, to: replacement, sourceVersion: "new", sourceModifiedAt: nil
        )
        let predecessor = geoPredecessorURL(for: destination)
        try FileManager.default.moveItem(at: destination, to: predecessor)
        try FileManager.default.moveItem(at: replacement, to: destination)

        let repository = try GeoDatabase.openExisting(at: destination)
        #expect(repository.metadata.sourceVersion == "new")
        #expect(geoDatabaseFamilySuffixes(at: predecessor).isEmpty)
    }
}

@Test func geoDatabaseOpenRestoresPredecessorAfterInterruptedInvalidPromotion() throws {
    try withGeoTestDirectory { directory in
        let destination = directory.appendingPathComponent("geolocation.sqlite")
        let source = directory.appendingPathComponent("dbip-city-lite-old.csv")
        try Data("8.8.8.0,8.8.8.255,NA,US,California,Old City,37.4,-122.1\n".utf8)
            .write(to: source)
        _ = try GeoCSVImporter.importFile(
            from: source, to: destination, sourceVersion: "old", sourceModifiedAt: nil
        )
        let predecessor = geoPredecessorURL(for: destination)
        try FileManager.default.moveItem(at: destination, to: predecessor)
        try Data("not a SQLite database".utf8).write(to: destination)

        let repository = try GeoDatabase.openExisting(at: destination)
        #expect(repository.metadata.sourceVersion == "old")
        #expect(geoDatabaseFamilySuffixes(at: predecessor).isEmpty)
    }
}

@Test func geoCSVImportRejectsMalformedAndUnboundedRecords() throws {
    try withGeoTestDirectory { directory in
        let destination = directory.appendingPathComponent("geolocation.sqlite")
        let malformed = directory.appendingPathComponent("malformed.csv")
        try Data("8.8.8.0,8.8.8.255,NA,US,California,\"unterminated,37,-122\n".utf8)
            .write(to: malformed)
        #expect(throws: GeoCSVImportError.self) {
            try GeoCSVImporter.importFile(
                from: malformed,
                to: destination,
                sourceVersion: "bad",
                sourceModifiedAt: nil
            )
        }

        let invalidCoordinate = directory.appendingPathComponent("invalid-coordinate.csv")
        try Data("8.8.8.0,8.8.8.255,NA,US,California,City,100,-122\n".utf8)
            .write(to: invalidCoordinate)
        #expect(throws: GeoCSVImportError.invalidRecord(line: 1)) {
            try GeoCSVImporter.importFile(
                from: invalidCoordinate,
                to: destination,
                sourceVersion: "bad",
                sourceModifiedAt: nil
            )
        }
    }
}

@Test func geoCSVImportAcceptsBOMHeaderAndRejectsSymbolicLinkSource() throws {
    try withGeoTestDirectory { directory in
        let destination = directory.appendingPathComponent("geolocation.sqlite")
        let source = directory.appendingPathComponent("dbip-city-lite-2026-08.csv")
        let csv = """
            \u{feff}ip_start,ip_end,continent,country,stateprov,city,latitude,longitude
            8.8.8.0,8.8.8.255,NA,US,California,"Mountain View",37.4,-122.1
            """
        try Data(csv.utf8).write(to: source)
        let metadata = try GeoCSVImporter.importFile(
            from: source,
            to: destination,
            sourceVersion: "2026-08",
            sourceModifiedAt: nil
        )
        #expect(metadata.recordCount == 1)
        let sourceDate = try #require(GeoCSVImporter.sourceDate(
            filename: source.lastPathComponent,
            modifiedAt: nil
        ))
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: try #require(TimeZone(secondsFromGMT: 0)),
            from: sourceDate
        )
        #expect(components.year == 2026)
        #expect(components.month == 8)

        let link = directory.appendingPathComponent("linked.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: GeoCSVImportError.unsupportedFile) {
            try GeoCSVImporter.importFile(
                from: link,
                to: destination,
                sourceVersion: "linked",
                sourceModifiedAt: nil
            )
        }
    }
}

private func endpoint(
    _ address: String,
    classes: Set<EndpointClass> = []
) throws -> Endpoint {
    Endpoint(
        address: try IPAddress(address),
        port: 443,
        hostname: nil,
        hostnameCoverage: .absent,
        classes: classes,
        interfaceSnapshotGeneration: 1
    )
}

private enum GeoPromotionTestError: Error, Equatable {
    case injected(GeoDatabasePromotionCheckpoint)
    case unableToPersistWAL(Int32)
}

private func preparePersistentGeoDatabaseWALFamily(at url: URL) throws {
    var configuration = Configuration()
    configuration.busyMode = .timeout(3)
    configuration.prepareDatabase { database in
        let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode = WAL")
        guard journalMode?.lowercased() == "wal" else {
            throw GeoPromotionTestError.unableToPersistWAL(SQLITE_ERROR)
        }
        try database.execute(sql: "PRAGMA wal_autocheckpoint = 0")
    }
    let database = try DatabaseQueue(path: url.path, configuration: configuration)
    try database.write { value in
        guard let connection = value.sqliteConnection else {
            throw GeoPromotionTestError.unableToPersistWAL(SQLITE_MISUSE)
        }
        var persistent: Int32 = 1
        let result = sqlite3_file_control(
            connection, "main", SQLITE_FCNTL_PERSIST_WAL, &persistent
        )
        guard result == SQLITE_OK else {
            throw GeoPromotionTestError.unableToPersistWAL(result)
        }
        try value.execute(
            sql: "UPDATE geo_metadata SET source_version = 'old-wal' WHERE singleton_id = 1"
        )
    }
    try database.close()
}

private func geoPredecessorURL(for destination: URL) -> URL {
    destination.deletingLastPathComponent().appendingPathComponent(
        ".\(destination.lastPathComponent).predecessor"
    )
}

private func geoDatabaseFamilySuffixes(at url: URL) -> Set<String> {
    Set(["", "-wal", "-shm", "-journal"].filter {
        FileManager.default.fileExists(atPath: url.path + $0)
    })
}

private func withGeoTestDirectory<T>(
    _ body: (URL) throws -> T
) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "abyss-geo-tests-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

private func withGeoTestDirectory<T>(
    _ body: (URL) async throws -> T
) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "abyss-geo-tests-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
