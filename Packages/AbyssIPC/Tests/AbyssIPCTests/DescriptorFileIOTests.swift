import Foundation
import Testing
@testable import AbyssIPC

@Test func descriptorInputRejectsSymlinkAndDetectsInPlaceChange() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appendingPathComponent("source.json")
    let link = directory.appendingPathComponent("link.json")
    try Data("abcd".utf8).write(to: source)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    #expect(throws: DescriptorFileError.self) {
        try DescriptorFileAccess.beginRead(path: link.path, maximumBytes: 10)
    }

    let input = try DescriptorFileAccess.beginRead(path: source.path, maximumBytes: 10)
    #expect(try input.readChunk(maximumBytes: 2) == Data("ab".utf8))
    let handle = try FileHandle(forWritingTo: source)
    try handle.write(contentsOf: Data("wxyz".utf8))
    try handle.close()
    _ = try input.readChunk(maximumBytes: 2)
    #expect(throws: DescriptorFileError.fileChangedWhileReading) { try input.finish() }
}

@Test func descriptorOutputIsOwnerOnlyAndAbortRemovesOnlyItsFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("output.json")
    let output = try DescriptorFileAccess.beginCreate(path: destination.path)
    try output.append(Data("safe".utf8))
    output.abort()
    #expect(!FileManager.default.fileExists(atPath: destination.path))

    let finished = try DescriptorFileAccess.beginCreate(path: destination.path)
    try finished.append(Data("safe".utf8))
    try finished.finish()
    let permissions = try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int
    #expect(permissions.map { $0 & 0o077 } == 0)
    #expect(try Data(contentsOf: destination) == Data("safe".utf8))
}

@Test func transferPumpHandlesShortReadsAndSerializedBackpressure() async throws {
    let source = Data((0..<17).map(UInt8.init))
    var cursor = 0
    let recorder = TransferRecorder()
    let count = try await CLITransferPump.upload(
        totalBytes: source.count,
        maximumChunkBytes: 8,
        read: { requested in
            let length = min(3, requested)
            let end = cursor + length
            defer { cursor = end }
            return source.subdata(in: cursor..<end)
        },
        send: { chunk, offset in
            try await recorder.record(chunk: chunk, offset: offset)
        }
    )
    #expect(count == source.count)
    #expect(await recorder.data == source)
    #expect(await recorder.maximumConcurrentSends == 1)
}

private actor TransferRecorder {
    private(set) var data = Data()
    private(set) var maximumConcurrentSends = 0
    private var activeSends = 0

    func record(chunk: Data, offset: Int) throws {
        guard offset == data.count else { throw CLITransferPumpError.invalidBounds }
        activeSends += 1
        maximumConcurrentSends = max(maximumConcurrentSends, activeSends)
        data.append(chunk)
        activeSends -= 1
    }
}
