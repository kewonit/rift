import Darwin
import Foundation
import Testing
@testable import AbyssControl

@Test func firstProcessLockWinsAndSecondLoses() throws {
    let directory = try processLockDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let first = try acquiredLock(in: directory)

    let second = try ProcessInstanceLock.acquire(in: directory)
    guard case .unavailable = second else {
        Issue.record("A second owner acquired the process lock")
        return
    }
    withExtendedLifetime(first) {}
}

@Test func releasedProcessDescriptorDoesNotLeaveStaleOwnership() throws {
    let directory = try processLockDirectory()
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    weak var released: ProcessInstanceLock?
    do {
        let first = try acquiredLock(in: directory)
        released = first
    }
    #expect(released == nil)

    let replacement = try acquiredLock(in: directory)
    withExtendedLifetime(replacement) {}
}

@Test func symbolicLinkProcessLockIsRejected() throws {
    let directory = try processLockDirectory(createLeaf: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let target = directory.deletingLastPathComponent().appendingPathComponent("target")
    try Data().write(to: target)
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("instance.lock"),
        withDestinationURL: target
    )

    #expect(throws: ProcessInstanceLockError.unsafeLockFile) {
        _ = try ProcessInstanceLock.acquire(in: directory)
    }
}

@Test func groupReadableProcessLockIsRejected() throws {
    let directory = try processLockDirectory(createLeaf: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let lock = directory.appendingPathComponent("instance.lock")
    try Data().write(to: lock)
    #expect(Darwin.chmod(lock.path, mode_t(0o640)) == 0)

    #expect(throws: ProcessInstanceLockError.unsafeLockFile) {
        _ = try ProcessInstanceLock.acquire(in: directory)
    }
}

private enum ProcessLockTestError: Error {
    case didNotAcquire
}

private func acquiredLock(in directory: URL) throws -> ProcessInstanceLock {
    switch try ProcessInstanceLock.acquire(in: directory) {
    case .acquired(let lock): return lock
    case .unavailable: throw ProcessLockTestError.didNotAcquire
    }
}

private func processLockDirectory(createLeaf: Bool = false) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    let directory = root.appendingPathComponent("instance", isDirectory: true)
    if createLeaf {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }
    return directory
}
