import Foundation
import GRDB

public actor DailyConfigurationBackup {
    private let database: DatabasePool
    private let directory: URL
    private let calendar: Calendar

    public init(database: DatabasePool, directory: URL) {
        self.database = database
        self.directory = directory
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        self.calendar = calendar
    }

    @discardableResult
    public func runIfNeeded(now: Date) throws -> URL? {
        let day = dayString(now)
        let alreadyCompleted = try database.read { database in
            try Bool.fetchOne(
                database,
                sql: "SELECT EXISTS(SELECT 1 FROM backup_runs WHERE day = ?)",
                arguments: [day]
            ) ?? false
        }
        guard !alreadyCompleted else { return nil }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent("config-\(day).sqlite")
        let temporary = directory.appendingPathComponent(".backup-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }

        try createBackup(at: temporary)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }

        try database.write { database in
            try database.execute(
                sql: "INSERT OR IGNORE INTO backup_runs (day, completed_at, path) VALUES (?, ?, ?)",
                arguments: [day, now.timeIntervalSince1970, destination.lastPathComponent]
            )
        }
        try pruneRetainingSeven()
        return destination
    }

    public func runPreRestore(now: Date) throws -> URL {
        try prepareDirectory()
        let timestamp = Int64(now.timeIntervalSince1970)
        let destination = directory.appendingPathComponent(
            "pre-restore-\(timestamp)-\(UUID().uuidString.prefix(8)).sqlite"
        )
        let temporary = directory.appendingPathComponent(".restore-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try createBackup(at: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try prunePreRestoreRetainingSeven()
        return destination
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func createBackup(at temporary: URL) throws {
        let target = try DatabaseQueue(path: temporary.path)
        do {
            try database.backup(to: target, pagesPerStep: 256)
            try target.writeWithoutTransaction { database in
                _ = try String.fetchOne(database, sql: "PRAGMA journal_mode = DELETE")
            }
            try target.close()
        } catch {
            try? target.close()
            throw error
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
    }

    private func prunePreRestoreRetainingSeven() throws {
        let values = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ).filter {
            $0.lastPathComponent.hasPrefix("pre-restore-")
                && $0.pathExtension == "sqlite"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted {
            let left = try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let right = try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return (left ?? .distantPast) > (right ?? .distantPast)
        }
        for url in values.dropFirst(7) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func pruneRetainingSeven() throws {
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: "SELECT day, path FROM backup_runs ORDER BY day DESC"
            )
        }
        for row in rows.dropFirst(7) {
            let day: String = row["day"]
            let path: String = row["path"]
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(path))
            try database.write { database in
                try database.execute(sql: "DELETE FROM backup_runs WHERE day = ?", arguments: [day])
            }
        }
    }

    private func dayString(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
