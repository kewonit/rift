import Darwin
import Foundation
import Testing
@testable import RiftControl

@Test func secureArchiveReadUsesABoundedRegularFileSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("archive.json")
    let expected = Data(repeating: 0x41, count: 3 * 64 * 1_024 + 17)
    try expected.write(to: url)

    #expect(try SecureArchiveFile.readSnapshot(at: url, maximumBytes: expected.count) == expected)
    #expect(throws: SecureArchiveFileError.oversized) {
        try SecureArchiveFile.readSnapshot(at: url, maximumBytes: expected.count - 1)
    }
}

@Test func secureArchiveReadRejectsSymlinksAndDirectories() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appendingPathComponent("target.json")
    try Data("{}".utf8).write(to: target)
    let link = directory.appendingPathComponent("archive.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    #expect(throws: SecureArchiveFileError.symbolicLink) {
        try SecureArchiveFile.readSnapshot(at: link, maximumBytes: 1_024)
    }
    #expect(throws: SecureArchiveFileError.notRegularFile) {
        try SecureArchiveFile.readSnapshot(at: directory, maximumBytes: 1_024)
    }
}

@Test func unsupportedOwnerOnlyPermissionsNeverReplaceExistingArchive() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("archive.json")
    let original = Data("original".utf8)
    try original.write(to: url)

    #expect(throws: SecureArchiveFileError.ownerOnlyPermissionsUnsupported) {
        try SecureArchiveFile.writeReplacing(
            Data("replacement".utf8),
            at: url,
            permissionValidator: { _ in false }
        )
    }
    #expect(try Data(contentsOf: url) == original)
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(names == [url.lastPathComponent])
}

@Test func secureArchiveWriteAtomicallyReplacesWithOwnerOnlyFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("archive.json")
    try Data("old".utf8).write(to: url)
    let replacement = Data("new archive".utf8)

    try SecureArchiveFile.writeReplacing(replacement, at: url)

    #expect(try Data(contentsOf: url) == replacement)
    var metadata = stat()
    #expect(lstat(url.path, &metadata) == 0)
    #expect(metadata.st_mode & S_IFMT == S_IFREG)
    #expect(metadata.st_uid == geteuid())
    #expect(metadata.st_mode & 0o077 == 0)
}

@Test func secureArchiveWriteDoesNotReplaceAFileCreatedDuringPromotion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("archive.json")
    let raced = Data("created concurrently".utf8)

    #expect(throws: SecureArchiveFileError.destinationChanged) {
        try SecureArchiveFile.writeReplacing(
            Data("new archive".utf8),
            at: url,
            permissionValidator: { _ in true },
            beforePromotion: { try raced.write(to: url) }
        )
    }
    #expect(try Data(contentsOf: url) == raced)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
}

@Test func secureArchiveWriteRollsBackAChangedDestination() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("archive.json")
    try Data("original".utf8).write(to: url)
    let raced = Data("changed concurrently with a different size".utf8)

    #expect(throws: SecureArchiveFileError.destinationChanged) {
        try SecureArchiveFile.writeReplacing(
            Data("new archive".utf8),
            at: url,
            permissionValidator: { _ in true },
            beforePromotion: { try raced.write(to: url) }
        )
    }
    #expect(try Data(contentsOf: url) == raced)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [url.lastPathComponent])
}
