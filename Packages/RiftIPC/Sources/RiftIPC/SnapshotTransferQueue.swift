import Foundation

public struct SnapshotTransferRequest: Sendable, Hashable {
    public let tuple: PolicyTuple
    public let schemaVersion: UInt16
    public let bytes: Data

    public init(tuple: PolicyTuple, schemaVersion: UInt16, bytes: Data) {
        self.tuple = tuple
        self.schemaVersion = schemaVersion
        self.bytes = bytes
    }
}

public struct SnapshotTransferChannel: Sendable {
    private let beginOperation: @Sendable (SnapshotTransferBegin) async throws -> Void
    private let appendOperation: @Sendable (SnapshotChunk) async throws -> Void
    private let finishOperation: @Sendable () async throws -> SnapshotFinishResult
    private let abortOperation: @Sendable () async -> Void

    public init(
        begin: @escaping @Sendable (SnapshotTransferBegin) async throws -> Void,
        append: @escaping @Sendable (SnapshotChunk) async throws -> Void,
        finish: @escaping @Sendable () async throws -> SnapshotFinishResult,
        abort: @escaping @Sendable () async -> Void
    ) {
        beginOperation = begin
        appendOperation = append
        finishOperation = finish
        abortOperation = abort
    }

    fileprivate func begin(_ header: SnapshotTransferBegin) async throws {
        try await beginOperation(header)
    }

    fileprivate func append(_ chunk: SnapshotChunk) async throws {
        try await appendOperation(chunk)
    }

    fileprivate func finish() async throws -> SnapshotFinishResult {
        try await finishOperation()
    }

    fileprivate func abort() async {
        await abortOperation()
    }
}

public enum SnapshotTransferQueueError: Error, Sendable, Equatable {
    case invalidRequest
    case queueFull
    case lineageConflict
    case generationHashMismatch
    case unexpectedResult
}

public actor SnapshotTransferQueue {
    private typealias Waiter = CheckedContinuation<SnapshotFinishResult, Error>

    private struct Work {
        var request: SnapshotTransferRequest
        var channel: SnapshotTransferChannel
        var waiters: [Waiter]
    }

    private static let maximumWaiters = 128
    private var inFlightRequest: SnapshotTransferRequest?
    private var inFlightWaiters: [Waiter] = []
    private var pending: Work?
    private var workerRunning = false

    public init() {}

    public func submit(
        _ request: SnapshotTransferRequest,
        channel: SnapshotTransferChannel
    ) async throws -> SnapshotFinishResult {
        guard request.tuple.generation > 0,
              request.schemaVersion > 0,
              request.tuple.hash.count == 32,
              !request.bytes.isEmpty,
              request.bytes.count <= IPCProtocolLimits.maximumSnapshotBytes else {
            throw SnapshotTransferQueueError.invalidRequest
        }
        guard inFlightWaiters.count + (pending?.waiters.count ?? 0)
            < Self.maximumWaiters else {
            throw SnapshotTransferQueueError.queueFull
        }
        return try await withCheckedThrowingContinuation { continuation in
            enqueue(request, channel: channel, waiter: continuation)
        }
    }

    private func enqueue(
        _ request: SnapshotTransferRequest,
        channel: SnapshotTransferChannel,
        waiter: Waiter
    ) {
        do {
            try validateCompatibility(request)
        } catch {
            waiter.resume(throwing: error)
            return
        }
        if var pending {
            if request.tuple.generation > pending.request.tuple.generation {
                pending.request = request
                pending.channel = channel
            }
            pending.waiters.append(waiter)
            self.pending = pending
            return
        }
        if let inFlightRequest,
           request.tuple.generation <= inFlightRequest.tuple.generation {
            inFlightWaiters.append(waiter)
            return
        }
        pending = Work(request: request, channel: channel, waiters: [waiter])
        guard !workerRunning else { return }
        workerRunning = true
        Task { await runWorker() }
    }

    private func validateCompatibility(_ request: SnapshotTransferRequest) throws {
        for existing in [inFlightRequest, pending?.request].compactMap({ $0 }) {
            guard existing.tuple.lineageID == request.tuple.lineageID else {
                throw SnapshotTransferQueueError.lineageConflict
            }
            if existing.tuple.generation == request.tuple.generation,
               existing.tuple.hash != request.tuple.hash {
                throw SnapshotTransferQueueError.generationHashMismatch
            }
        }
    }

    private func runWorker() async {
        while let work = takePending() {
            let outcome: Result<SnapshotFinishResult, Error>
            do {
                outcome = .success(try await Self.transfer(work.request, over: work.channel))
            } catch {
                outcome = .failure(error)
            }
            completeInFlight(with: outcome)
        }
        workerRunning = false
    }

    private func takePending() -> Work? {
        guard let work = pending else { return nil }
        pending = nil
        inFlightRequest = work.request
        inFlightWaiters = work.waiters
        return work
    }

    private func completeInFlight(with outcome: Result<SnapshotFinishResult, Error>) {
        let waiters = inFlightWaiters
        inFlightRequest = nil
        inFlightWaiters = []
        for waiter in waiters {
            switch outcome {
            case .success(let result): waiter.resume(returning: result)
            case .failure(let error): waiter.resume(throwing: error)
            }
        }
    }

    private static func transfer(
        _ request: SnapshotTransferRequest,
        over channel: SnapshotTransferChannel
    ) async throws -> SnapshotFinishResult {
        do {
            try await channel.begin(SnapshotTransferBegin(
                lineageID: request.tuple.lineageID,
                generation: request.tuple.generation,
                schemaVersion: request.schemaVersion,
                byteCount: request.bytes.count,
                hash: request.tuple.hash
            ))
            var offset = 0
            while offset < request.bytes.count {
                let end = min(offset + IPCProtocolLimits.maximumChunkBytes, request.bytes.count)
                try await channel.append(SnapshotChunk(
                    offset: offset,
                    bytes: request.bytes.subdata(in: offset..<end)
                ))
                offset = end
            }
            let result = try await channel.finish()
            guard result.tuple == request.tuple else {
                throw SnapshotTransferQueueError.unexpectedResult
            }
            return result
        } catch {
            await channel.abort()
            throw error
        }
    }
}
