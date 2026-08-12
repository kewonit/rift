import Foundation
import GRDB
import Testing
@testable import AbyssControl

@Test func futureHistorySchemaInWALIsRejectedWithoutMutatingDatabaseFamily() throws {
    let directory = try historyPreflightTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let database = try HistoryDatabase.open(at: url)
    defer { try? database.close() }
    try database.write { database in
        try database.execute(sql: "PRAGMA wal_autocheckpoint = 0")
        try database.execute(
            sql: "INSERT INTO grdb_migrations (identifier) VALUES ('history-v999-future')"
        )
    }
    let before = try HistoryDatabaseFamilySnapshot(at: url)
    #expect(before.main != nil)
    #expect(before.wal != nil)
    #expect(before.shm != nil)

    #expect(throws: HistoryDatabaseError.unsupportedSchema) {
        _ = try HistoryDatabase.open(at: url)
    }

    #expect(try HistoryDatabaseFamilySnapshot(at: url) == before)
}

@Test func futureHistorySchemaWithoutWALIsRejectedWithoutCreatingSidecars() throws {
    let directory = try historyPreflightTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixtureURL = directory.appendingPathComponent("fixture.sqlite")
    let initialDatabase = try HistoryDatabase.open(at: fixtureURL)
    try initialDatabase.close()
    let fixtureDatabase = try DatabaseQueue(path: fixtureURL.path)
    defer { try? fixtureDatabase.close() }
    try fixtureDatabase.writeWithoutTransaction { database in
        let journalMode = try String.fetchOne(database, sql: "PRAGMA journal_mode = DELETE")
        #expect(journalMode?.lowercased() == "delete")
        try database.execute(
            sql: "INSERT INTO grdb_migrations (identifier) VALUES ('history-v999-future')"
        )
    }
    try fixtureDatabase.close()
    let url = directory.appendingPathComponent("history.sqlite")
    try FileManager.default.copyItem(at: fixtureURL, to: url)
    let before = try HistoryDatabaseFamilySnapshot(at: url)
    #expect(before.main != nil)
    #expect(before.wal == nil)
    #expect(before.shm == nil)

    #expect(throws: HistoryDatabaseError.unsupportedSchema) {
        _ = try HistoryDatabase.openRecovering(
            at: url,
            now: Date(timeIntervalSince1970: 1_700_000_004)
        )
    }

    #expect(try HistoryDatabaseFamilySnapshot(at: url) == before)
    #expect(!FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("History Quarantine").path
    ))
}

private struct HistoryDatabaseFamilySnapshot: Equatable {
    let main: Data?
    let wal: Data?
    let shm: Data?

    init(at url: URL) throws {
        main = try Self.dataIfPresent(at: url)
        wal = try Self.dataIfPresent(at: URL(fileURLWithPath: url.path + "-wal"))
        shm = try Self.dataIfPresent(at: URL(fileURLWithPath: url.path + "-shm"))
    }

    private static func dataIfPresent(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
}

private func historyPreflightTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
