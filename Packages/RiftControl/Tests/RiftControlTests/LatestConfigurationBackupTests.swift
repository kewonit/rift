import Foundation
import RiftControl
import Testing

private struct Damaged: Error {}

private func directory(_ names: [String]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rift-backups-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    for name in names {
        FileManager.default.createFile(atPath: url.appendingPathComponent(name).path, contents: Data())
    }
    return url
}

private let draft = PolicyConfigurationDraft(
    lineageID: UUID(), authorizedUID: 501, operationMode: .silentAllow,
    activeProfileID: nil, enabledLocalGroupIDs: [], rules: []
)

@Test func theNewestReadableBackupIsChosen() throws {
    let folder = try directory(["config-2026-11-01.sqlite", "config-2026-11-05.sqlite", "config-2026-11-03.sqlite"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let found = LatestConfigurationBackup.newest(in: folder) { _ in draft }
    #expect(found?.day == "2026-11-05")
}

@Test func aDamagedBackupIsSkippedForAnOlderGoodOne() throws {
    let folder = try directory(["config-2026-11-05.sqlite", "config-2026-11-04.sqlite"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let found = LatestConfigurationBackup.newest(in: folder) { url in
        if url.lastPathComponent.contains("11-05") { throw Damaged() }
        return draft
    }
    #expect(found?.day == "2026-11-04")
}

@Test func anEmptyBackupIsSkipped() throws {
    let folder = try directory(["config-2026-11-05.sqlite", "config-2026-11-04.sqlite"])
    defer { try? FileManager.default.removeItem(at: folder) }
    let found = LatestConfigurationBackup.newest(in: folder) { url in
        url.lastPathComponent.contains("11-05") ? nil : draft
    }
    #expect(found?.day == "2026-11-04")
}

@Test func otherFilesAreIgnored() throws {
    let folder = try directory(["pre-restore-1.sqlite", "notes.txt", "config-notes.txt"])
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(LatestConfigurationBackup.newest(in: folder) { _ in draft } == nil)
}

@Test func noBackupsMeansNothingToRestore() throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("rift-none-\(UUID().uuidString)")
    #expect(LatestConfigurationBackup.newest(in: missing) { _ in draft } == nil)
}
