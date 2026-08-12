import RiftCore
import Foundation
import GRDB

public enum GeoCSVImportError: Error, Sendable, Equatable {
    case unsupportedFile
    case fileTooLarge
    case emptyDatabase
    case tooManyRecords
    case malformedCSV(line: Int)
    case invalidRecord(line: Int)
    case overlappingRanges(line: Int)
    case unsafeDestination
}

public enum GeoCSVImporter {
    public static let maximumFileBytes = 1_024 * 1_024 * 1_024
    public static let maximumRecords = 10_000_000
    public static let sourceName = "DB-IP City Lite"
    public static let attribution = "IP Geolocation by DB-IP"
    public static let sourceURLString = "https://db-ip.com/db/lite.php"
    public static let licenseURLString = "https://creativecommons.org/licenses/by/4.0/"

    public static func importFile(
        from source: URL,
        to destination: URL,
        sourceVersion: String,
        sourceModifiedAt: Date?,
        importedAt: Date = Date()
    ) throws -> GeoDatabaseMetadata {
        try importFile(
            from: source,
            to: destination,
            sourceVersion: sourceVersion,
            sourceModifiedAt: sourceModifiedAt,
            importedAt: importedAt,
            promotionFaultInjector: { _ in }
        )
    }

    static func importFile(
        from source: URL,
        to destination: URL,
        sourceVersion: String,
        sourceModifiedAt: Date?,
        importedAt: Date = Date(),
        promotionFaultInjector: GeoDatabasePromotion.FaultInjector
    ) throws -> GeoDatabaseMetadata {
        guard source.pathExtension.lowercased() == "csv" else {
            throw GeoCSVImportError.unsupportedFile
        }
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let fileSize = values.fileSize else {
            throw GeoCSVImportError.unsupportedFile
        }
        guard fileSize <= maximumFileBytes else {
            throw GeoCSVImportError.fileTooLarge
        }
        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        if manager.fileExists(atPath: directory.path) {
            let directoryValues = try directory.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true else {
                throw GeoCSVImportError.unsafeDestination
            }
        }
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let staging = directory.appendingPathComponent(
            ".geolocation-import-\(UUID().uuidString.lowercased()).sqlite"
        )
        defer { try? manager.removeItem(at: staging) }
        let metadata = try buildStagingDatabase(
            source: source,
            staging: staging,
            sourceVersion: bounded(sourceVersion, maximum: 120),
            sourceModifiedAt: sourceModifiedAt,
            importedAt: importedAt
        )
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        try GeoDatabasePromotion.promote(
            staging: staging,
            to: destination,
            expectedMetadata: metadata,
            faultInjector: promotionFaultInjector
        )
        return metadata
    }

    public static func versionLabel(filename: String, modifiedAt: Date?) -> String {
        let lower = filename.lowercased()
        let prefix = "dbip-city-lite-"
        if lower.hasPrefix(prefix), lower.hasSuffix(".csv") {
            let start = lower.index(lower.startIndex, offsetBy: prefix.count)
            let end = lower.index(lower.endIndex, offsetBy: -4)
            let candidate = String(lower[start..<end])
            if !candidate.isEmpty, candidate.count <= 32 { return candidate }
        }
        if let modifiedAt {
            return modifiedAt.formatted(.iso8601.year().month().day())
        }
        return "manually imported"
    }

    public static func sourceDate(filename: String, modifiedAt: Date?) -> Date? {
        let parts = versionLabel(filename: filename, modifiedAt: nil).split(separator: "-")
        if parts.count == 2,
           let year = Int(parts[0]), let month = Int(parts[1]),
           (2000...3000).contains(year), (1...12).contains(month),
           let utc = TimeZone(secondsFromGMT: 0) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = utc
            return calendar.date(from: DateComponents(year: year, month: month, day: 1))
        }
        return modifiedAt
    }

    private static func buildStagingDatabase(
        source: URL,
        staging: URL,
        sourceVersion: String,
        sourceModifiedAt: Date?,
        importedAt: Date
    ) throws -> GeoDatabaseMetadata {
        let queue = try GeoDatabase.createStaging(at: staging)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var parser = CSVStreamParser()
        var count = 0
        var previousUpper: [IPAddress.Family: IPAddress] = [:]
        try queue.write { database in
            let insert = try database.makeStatement(sql: """
                INSERT INTO geo_ranges
                    (family, ip_start, ip_end, continent, country, region, city,
                     latitude, longitude)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                try parser.consume(chunk) { fields, line in
                    if count == 0, line == 1, isHeader(fields) { return }
                    guard count < maximumRecords else { throw GeoCSVImportError.tooManyRecords }
                    let value = try record(fields, line: line)
                    if let prior = previousUpper[value.lower.family], value.lower <= prior {
                        throw GeoCSVImportError.overlappingRanges(line: line)
                    }
                    previousUpper[value.lower.family] = value.upper
                    try insert.execute(arguments: [
                        Int(value.lower.family.rawValue), Data(value.lower.bytes),
                        Data(value.upper.bytes), value.location.continentCode,
                        value.location.countryCode, value.location.region,
                        value.location.city, value.location.latitude,
                        value.location.longitude,
                    ])
                    count += 1
                }
            }
            try parser.finish { fields, line in
                if count == 0, line == 1, isHeader(fields) { return }
                guard count < maximumRecords else { throw GeoCSVImportError.tooManyRecords }
                let value = try record(fields, line: line)
                if let prior = previousUpper[value.lower.family], value.lower <= prior {
                    throw GeoCSVImportError.overlappingRanges(line: line)
                }
                try insert.execute(arguments: [
                    Int(value.lower.family.rawValue), Data(value.lower.bytes),
                    Data(value.upper.bytes), value.location.continentCode,
                    value.location.countryCode, value.location.region,
                    value.location.city, value.location.latitude,
                    value.location.longitude,
                ])
                count += 1
            }
            guard count > 0 else { throw GeoCSVImportError.emptyDatabase }
            try database.execute(
                sql: """
                    INSERT INTO geo_metadata
                        (singleton_id, source_name, source_version, source_modified_at,
                         imported_at, record_count)
                    VALUES (1, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    sourceName, sourceVersion, sourceModifiedAt?.timeIntervalSince1970,
                    importedAt.timeIntervalSince1970, count,
                ]
            )
        }
        return GeoDatabaseMetadata(
            sourceName: sourceName,
            sourceVersion: sourceVersion,
            sourceModifiedAt: sourceModifiedAt,
            importedAt: importedAt,
            recordCount: count
        )
    }

    private static func record(
        _ rawFields: [String],
        line: Int
    ) throws -> (lower: IPAddress, upper: IPAddress, location: GeoLocation) {
        guard rawFields.count == 8 else { throw GeoCSVImportError.invalidRecord(line: line) }
        var fields = rawFields
        if line == 1, fields[0].hasPrefix("\u{feff}") { fields[0].removeFirst() }
        guard let lower = try? IPAddress(fields[0]),
              let upper = try? IPAddress(fields[1]),
              lower.family == upper.family, lower <= upper,
              let latitude = Double(fields[6]), let longitude = Double(fields[7]),
              fields[2...5].allSatisfy({ validText($0, maximum: 120) }) else {
            throw GeoCSVImportError.invalidRecord(line: line)
        }
        do {
            return (lower, upper, try GeoLocation(
                continentCode: fields[2],
                countryCode: fields[3],
                region: fields[4],
                city: fields[5],
                latitude: latitude,
                longitude: longitude
            ))
        } catch {
            throw GeoCSVImportError.invalidRecord(line: line)
        }
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        value.count <= maximum && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func isHeader(_ fields: [String]) -> Bool {
        guard var first = fields.first else { return false }
        if first.hasPrefix("\u{feff}") { first.removeFirst() }
        return first.lowercased() == "ip_start"
    }

    private static func bounded(_ value: String, maximum: Int) -> String {
        String(value.prefix(maximum))
    }
}

private struct CSVStreamParser {
    private var fields: [String] = []
    private var field = Data()
    private var inQuotes = false
    private var afterQuote = false
    private var recordBytes = 0
    private var line = 1
    private var recordLine = 1

    mutating func consume(
        _ data: Data,
        record: ([String], Int) throws -> Void
    ) throws {
        for byte in data {
            recordBytes += 1
            guard recordBytes <= 4_096 else { throw GeoCSVImportError.malformedCSV(line: recordLine) }
            if inQuotes {
                if byte == 34 {
                    inQuotes = false
                    afterQuote = true
                } else {
                    field.append(byte)
                    if byte == 10 { line += 1 }
                }
                continue
            }
            if afterQuote {
                if byte == 34 {
                    field.append(byte)
                    inQuotes = true
                    afterQuote = false
                } else if byte == 44 {
                    try finishField()
                    afterQuote = false
                } else if byte == 10 {
                    try finishField()
                    try emit(record)
                    afterQuote = false
                    line += 1
                } else if byte != 13 {
                    throw GeoCSVImportError.malformedCSV(line: recordLine)
                }
                continue
            }
            switch byte {
            case 34:
                guard field.isEmpty else { throw GeoCSVImportError.malformedCSV(line: recordLine) }
                inQuotes = true
            case 44:
                try finishField()
            case 10:
                try finishField()
                try emit(record)
                line += 1
            case 13:
                break
            default:
                field.append(byte)
            }
        }
    }

    mutating func finish(record: ([String], Int) throws -> Void) throws {
        guard !inQuotes else { throw GeoCSVImportError.malformedCSV(line: recordLine) }
        guard recordBytes > 0 || !field.isEmpty || !fields.isEmpty else { return }
        try finishField()
        try emit(record)
    }

    private mutating func finishField() throws {
        guard let value = String(data: field, encoding: .utf8) else {
            throw GeoCSVImportError.malformedCSV(line: recordLine)
        }
        fields.append(value)
        field.removeAll(keepingCapacity: true)
    }

    private mutating func emit(_ record: ([String], Int) throws -> Void) throws {
        try record(fields, recordLine)
        fields.removeAll(keepingCapacity: true)
        field.removeAll(keepingCapacity: true)
        recordBytes = 0
        recordLine = line + 1
    }
}
