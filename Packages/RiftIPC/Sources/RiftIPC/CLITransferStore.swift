import Foundation

public enum CLITransferStoreError: Error, Sendable, Equatable {
    case busy
    case invalidTransfer
}

public actor CLITransferStore {
    private struct Download {
        let data: Data
        let expiresAt: Date
    }

    private struct Upload {
        let totalBytes: Int
        var data: Data
        let expiresAt: Date
    }

    private var downloads: [UUID: Download] = [:]
    private var uploads: [UUID: Upload] = [:]
    private let maximumConcurrentTransfers: Int

    public init(maximumConcurrentTransfers: Int = 4) {
        self.maximumConcurrentTransfers = min(max(1, maximumConcurrentTransfers), 16)
    }

    public func beginDownload(data: Data, now: Date) throws -> CLITransferDescriptor {
        prune(now: now)
        guard downloads.count + uploads.count < maximumConcurrentTransfers else {
            throw CLITransferStoreError.busy
        }
        let descriptor = try CLITransferDescriptor(totalBytes: data.count)
        downloads[descriptor.transferID] = Download(
            data: data,
            expiresAt: now.addingTimeInterval(IPCProtocolLimits.transferDeadlineSeconds)
        )
        return descriptor
    }

    public func readDownload(_ read: CLITransferRead, now: Date) throws -> CLITransferChunk {
        prune(now: now)
        guard let transfer = downloads[read.transferID],
              read.offset <= transfer.data.count else {
            throw CLITransferStoreError.invalidTransfer
        }
        let end = min(transfer.data.count, read.offset + read.maximumBytes)
        return try CLITransferChunk(
            transferID: read.transferID,
            offset: read.offset,
            bytes: transfer.data.subdata(in: read.offset..<end)
        )
    }

    public func beginUpload(_ descriptor: CLITransferDescriptor, now: Date) throws {
        prune(now: now)
        guard downloads.count + uploads.count < maximumConcurrentTransfers,
              uploads[descriptor.transferID] == nil else {
            throw CLITransferStoreError.busy
        }
        uploads[descriptor.transferID] = Upload(
            totalBytes: descriptor.totalBytes,
            data: Data(),
            expiresAt: now.addingTimeInterval(IPCProtocolLimits.transferDeadlineSeconds)
        )
    }

    public func appendUpload(_ chunk: CLITransferChunk, now: Date) throws {
        prune(now: now)
        guard var upload = uploads[chunk.transferID],
              chunk.offset == upload.data.count,
              upload.data.count + chunk.bytes.count <= upload.totalBytes else {
            throw CLITransferStoreError.invalidTransfer
        }
        upload.data.append(chunk.bytes)
        uploads[chunk.transferID] = upload
    }

    public func finishUpload(_ transferID: UUID, now: Date) throws -> Data {
        prune(now: now)
        guard let upload = uploads[transferID], upload.data.count == upload.totalBytes else {
            throw CLITransferStoreError.invalidTransfer
        }
        uploads.removeValue(forKey: transferID)
        return upload.data
    }

    public func cancel(_ transferID: UUID) {
        downloads.removeValue(forKey: transferID)
        uploads.removeValue(forKey: transferID)
    }

    private func prune(now: Date) {
        downloads = downloads.filter { $0.value.expiresAt > now }
        uploads = uploads.filter { $0.value.expiresAt > now }
    }
}
