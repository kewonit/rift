import Foundation

public enum CLITransferPumpError: Error, Sendable, Equatable {
    case invalidBounds
    case emptyChunk
    case oversizedChunk
}

public enum CLITransferPump {
    @discardableResult
    public static func upload(
        totalBytes: Int,
        maximumChunkBytes: Int,
        read: (Int) throws -> Data,
        send: (Data, Int) async throws -> Void
    ) async throws -> Int {
        try validate(totalBytes: totalBytes, maximumChunkBytes: maximumChunkBytes)
        var offset = 0
        while offset < totalBytes {
            try Task.checkCancellation()
            let requested = min(maximumChunkBytes, totalBytes - offset)
            let chunk = try read(requested)
            guard !chunk.isEmpty else { throw CLITransferPumpError.emptyChunk }
            guard chunk.count <= requested else { throw CLITransferPumpError.oversizedChunk }
            try await send(chunk, offset)
            offset += chunk.count
        }
        return offset
    }

    @discardableResult
    public static func download(
        totalBytes: Int,
        maximumChunkBytes: Int,
        fetch: (Int, Int) async throws -> Data,
        write: (Data) throws -> Void
    ) async throws -> Int {
        try validate(totalBytes: totalBytes, maximumChunkBytes: maximumChunkBytes)
        var offset = 0
        while offset < totalBytes {
            try Task.checkCancellation()
            let requested = min(maximumChunkBytes, totalBytes - offset)
            let chunk = try await fetch(offset, requested)
            guard !chunk.isEmpty else { throw CLITransferPumpError.emptyChunk }
            guard chunk.count <= requested else { throw CLITransferPumpError.oversizedChunk }
            try write(chunk)
            offset += chunk.count
        }
        return offset
    }

    private static func validate(totalBytes: Int, maximumChunkBytes: Int) throws {
        guard totalBytes >= 0,
              totalBytes <= IPCProtocolLimits.maximumSnapshotBytes,
              maximumChunkBytes > 0,
              maximumChunkBytes <= IPCProtocolLimits.maximumChunkBytes else {
            throw CLITransferPumpError.invalidBounds
        }
    }
}
