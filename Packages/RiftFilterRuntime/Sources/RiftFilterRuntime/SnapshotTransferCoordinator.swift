import RiftIPC
import Foundation

public enum SnapshotTransferError: Error, Sendable, Equatable {
    case transferBusy
    case noTransfer
    case invalidHeader
    case invalidOffset(expected: Int, received: Int)
    case invalidChunkSize(Int)
    case overflow
    case incomplete(expected: Int, received: Int)
    case deadlineExceeded
    case payloadHeaderMismatch
    case incompatibleProtocol
}

public actor SnapshotTransferCoordinator {
    private struct Staging: Sendable {
        let header: SnapshotTransferBegin
        let deadline: Date
        var bytes: Data
    }

    private let store: RootPolicyStore
    private var staging: Staging?

    public init(store: RootPolicyStore) {
        self.store = store
    }

    public func begin(_ header: SnapshotTransferBegin, now: Date) throws {
        if let current = staging {
            guard now > current.deadline else { throw SnapshotTransferError.transferBusy }
            staging = nil
        }
        guard header.generation > 0,
              header.schemaVersion == CompiledPolicyPayload.currentSchemaVersion,
              header.byteCount >= 0,
              header.byteCount <= IPCProtocolLimits.maximumSnapshotBytes,
              header.hash.count == 32 else { throw SnapshotTransferError.invalidHeader }
        staging = Staging(
            header: header,
            deadline: now.addingTimeInterval(IPCProtocolLimits.transferDeadlineSeconds),
            bytes: Data()
        )
        staging?.bytes.reserveCapacity(header.byteCount)
    }

    public func append(offset: Int, chunk: Data, now: Date) throws {
        guard var current = staging else { throw SnapshotTransferError.noTransfer }
        guard now <= current.deadline else {
            staging = nil
            throw SnapshotTransferError.deadlineExceeded
        }
        guard offset == current.bytes.count else {
            throw SnapshotTransferError.invalidOffset(expected: current.bytes.count, received: offset)
        }
        guard !chunk.isEmpty, chunk.count <= IPCProtocolLimits.maximumChunkBytes else {
            throw SnapshotTransferError.invalidChunkSize(chunk.count)
        }
        let (newCount, overflow) = current.bytes.count.addingReportingOverflow(chunk.count)
        guard !overflow, newCount <= current.header.byteCount else { throw SnapshotTransferError.overflow }
        current.bytes.append(chunk)
        staging = current
    }

    public func finish(now: Date) async throws -> RecoveredPolicy {
        guard let current = staging else { throw SnapshotTransferError.noTransfer }
        staging = nil
        guard now <= current.deadline else { throw SnapshotTransferError.deadlineExceeded }
        guard current.bytes.count == current.header.byteCount else {
            throw SnapshotTransferError.incomplete(
                expected: current.header.byteCount,
                received: current.bytes.count
            )
        }
        let artifact = try PolicyArtifact(bytes: current.bytes, hash: current.header.hash)
        let payload = try artifact.decode()
        guard ProtocolVersion.current.supports(
            minimum: payload.compatibility.minimumExtensionProtocol
        ) else {
            throw SnapshotTransferError.incompatibleProtocol
        }
        guard payload.lineageID == current.header.lineageID,
              payload.generation == current.header.generation,
              payload.schemaVersion == current.header.schemaVersion else {
            throw SnapshotTransferError.payloadHeaderMismatch
        }
        return try await store.promote(artifact)
    }

    public func abort() {
        staging = nil
    }

    public func hasStagingTransfer() -> Bool { staging != nil }
}
