import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AbyssCore

@Test func executableHasherUsesFixedChunksAndMatchesSHA256() throws {
    let directory = try makeIdentityTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fixture")
    let content = Data((0..<(19 * 1_024 + 37)).map { UInt8($0 % 251) })
    try writeExecutable(content, to: executable)
    let chunks = ChunkProbe()

    let digest = try SecureExecutableHasher.hash(
        at: executable,
        maximumBytes: 32 * 1_024,
        chunkBytes: 4 * 1_024,
        didReadChunk: chunks.record
    )

    #expect(chunks.maximum == 4 * 1_024)
    #expect(chunks.total == content.count)
    #expect(digest.description == Data(SHA256.hash(data: content)).hexString)
}

@Test func executableHasherRejectsOversizeBeforeReading() throws {
    let directory = try makeIdentityTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("oversize")
    let descriptor = executable.path.withCString {
        Darwin.open($0, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0o700)
    }
    try #require(descriptor >= 0)
    try #require(Darwin.ftruncate(descriptor, 8_193) == 0)
    _ = Darwin.close(descriptor)
    let chunks = ChunkProbe()

    #expect(throws: SecureExecutableHashError.fileTooLarge(maximum: 8_192, actual: 8_193)) {
        try SecureExecutableHasher.hash(
            at: executable,
            maximumBytes: 8_192,
            chunkBytes: 1_024,
            didReadChunk: chunks.record
        )
    }
    #expect(chunks.total == 0)
}

@Test func executableHasherRejectsSymbolicLinksAndUnsafeModes() throws {
    let directory = try makeIdentityTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fixture")
    let link = directory.appendingPathComponent("fixture-link")
    try writeExecutable(Data("fixture".utf8), to: executable)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)

    #expect(throws: SecureExecutableHashError.symbolicLink) {
        try SecureExecutableHasher.hash(at: link)
    }
    try #require(Darwin.chmod(executable.path, 0o777) == 0)
    #expect(throws: SecureExecutableHashError.unsafePermissions) {
        try SecureExecutableHasher.hash(at: executable)
    }
}

@Test func executableHasherRejectsNonRegularFilesWithoutOpeningThem() throws {
    let directory = try makeIdentityTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let namedPipe = directory.appendingPathComponent("pipe")
    try #require(Darwin.mkfifo(namedPipe.path, 0o700) == 0)
    #expect(throws: SecureExecutableHashError.notRegularFile) {
        try SecureExecutableHasher.hash(at: namedPipe)
    }
}

@Test func executableHasherRejectsPathReplacementDuringRead() throws {
    let directory = try makeIdentityTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fixture")
    let displaced = directory.appendingPathComponent("fixture-before-replacement")
    try writeExecutable(Data(repeating: 0x41, count: 12 * 1_024), to: executable)
    let mutation = OneShot()

    #expect(throws: SecureExecutableHashError.fileChanged) {
        try SecureExecutableHasher.hash(
            at: executable,
            maximumBytes: 16 * 1_024,
            chunkBytes: 4 * 1_024,
            didReadChunk: { _ in
                mutation.run {
                    _ = executable.path.withCString { source in
                        displaced.path.withCString { destination in
                            Darwin.rename(source, destination)
                        }
                    }
                    _ = replacementExecutable(at: executable)
                }
            }
        )
    }
}

@Test func executableHasherRejectsSameInodeMutationDuringRead() throws {
    let directory = try makeIdentityTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fixture")
    try writeExecutable(Data(repeating: 0x51, count: 12 * 1_024), to: executable)
    let mutationDescriptor = executable.path.withCString {
        Darwin.open($0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    try #require(mutationDescriptor >= 0)
    defer { _ = Darwin.close(mutationDescriptor) }
    let mutation = OneShot()

    #expect(throws: SecureExecutableHashError.fileChanged) {
        try SecureExecutableHasher.hash(
            at: executable,
            maximumBytes: 16 * 1_024,
            chunkBytes: 4 * 1_024,
            didReadChunk: { _ in
                mutation.run {
                    var byte: UInt8 = 0x52
                    _ = Darwin.pwrite(mutationDescriptor, &byte, 1, 0)
                    _ = Darwin.fsync(mutationDescriptor)
                }
            }
        )
    }
}

@Test func executableHasherHonorsCancellationBetweenChunks() throws {
    let directory = try makeIdentityTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let executable = directory.appendingPathComponent("fixture")
    try writeExecutable(Data(repeating: 0x61, count: 12 * 1_024), to: executable)
    let cancellation = CancellationProbe()

    #expect(throws: SecureExecutableHashError.cancelled) {
        try SecureExecutableHasher.hash(
            at: executable,
            maximumBytes: 16 * 1_024,
            chunkBytes: 4 * 1_024,
            shouldCancel: cancellation.isCancelled,
            didReadChunk: { _ in cancellation.cancel() }
        )
    }
    #expect(cancellation.chunkTriggered)
}

@Test func identityWorkerPoolNeverRunsMoreThanTwoItems() throws {
    let pool = BoundedIdentityWorkerPool(label: "io.abyss.tests.identity-workers")
    let probe = ConcurrencyProbe()
    let release = DispatchSemaphore(value: 0)
    let completion = DispatchSemaphore(value: 0)
    let itemCount = 10

    for _ in 0..<itemCount {
        pool.submit {
            probe.enter()
            _ = release.wait(timeout: .now() + 5)
            probe.leave()
            completion.signal()
        }
    }
    for _ in 0..<BoundedIdentityWorkerPool.maximumConcurrentWorkItems {
        try #require(probe.started.wait(timeout: .now() + 2) == .success)
    }
    #expect(probe.startedCount == 2)
    #expect(probe.maximumActive == 2)

    for _ in 0..<itemCount { release.signal() }
    for _ in 0..<itemCount {
        try #require(completion.wait(timeout: .now() + 2) == .success)
    }
    #expect(probe.maximumActive == 2)
    #expect(probe.finishedCount == itemCount)
}

private func makeIdentityTestDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("abyss-identity-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func writeExecutable(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .withoutOverwriting)
    try #require(Darwin.chmod(url.path, 0o700) == 0)
}

private func replacementExecutable(at url: URL) -> Bool {
    let descriptor = url.path.withCString {
        Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o700)
    }
    guard descriptor >= 0 else { return false }
    var bytes = [UInt8](repeating: 0x42, count: 12 * 1_024)
    let written = bytes.withUnsafeMutableBytes {
        Darwin.write(descriptor, $0.baseAddress, $0.count)
    }
    _ = Darwin.close(descriptor)
    return written == bytes.count
}

private final class ChunkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []

    func record(_ count: Int) {
        lock.withLock { counts.append(count) }
    }

    var maximum: Int { lock.withLock { counts.max() ?? 0 } }
    var total: Int { lock.withLock { counts.reduce(0, +) } }
}

private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func run(_ body: () -> Void) {
        let shouldRun = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldRun { body() }
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    func isCancelled() -> Bool { lock.withLock { cancelled } }
    var chunkTriggered: Bool { isCancelled() }
}

private final class ConcurrencyProbe: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var active = 0
    private var maximum = 0
    private var startedItems = 0
    private var finishedItems = 0

    func enter() {
        lock.withLock {
            active += 1
            startedItems += 1
            maximum = max(maximum, active)
        }
        started.signal()
    }

    func leave() {
        lock.withLock {
            active -= 1
            finishedItems += 1
        }
    }

    var maximumActive: Int { lock.withLock { maximum } }
    var startedCount: Int { lock.withLock { startedItems } }
    var finishedCount: Int { lock.withLock { finishedItems } }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
