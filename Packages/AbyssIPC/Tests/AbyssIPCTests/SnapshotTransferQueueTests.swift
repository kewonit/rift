import Foundation
import Testing
@testable import AbyssIPC

@Test(arguments: LostReplyPoint.allCases)
func lostTransferReplyAbortsStagingAndAllowsRetry(_ point: LostReplyPoint) async throws {
    let lineageID = UUID()
    let server = FakeTransferServer(lostReplyAt: point)
    let queue = SnapshotTransferQueue()
    let request = transferRequest(lineageID: lineageID, generation: 1)

    await #expect(throws: FakeTransferError.lostReply) {
        try await queue.submit(request, channel: server.channel())
    }
    let failed = await server.status()
    #expect(failed.abortCount == 1)
    #expect(!failed.hasStaging)

    let result = try await queue.submit(request, channel: server.channel())
    #expect(result.tuple == request.tuple)
    let recovered = await server.status()
    #expect(recovered.persistedGeneration == 1)
    #expect(!recovered.hasStaging)
}

@Test func simultaneousGenerationsAreSerializedAndEndAtNewest() async throws {
    let lineageID = UUID()
    let server = FakeTransferServer(pauseFirstBegin: true)
    let queue = SnapshotTransferQueue()
    let firstRequest = transferRequest(lineageID: lineageID, generation: 7)
    let newestRequest = transferRequest(lineageID: lineageID, generation: 8)

    let first = Task {
        try await queue.submit(firstRequest, channel: server.channel())
    }
    await server.waitUntilFirstBeginIsPaused()
    let newest = Task {
        try await queue.submit(newestRequest, channel: server.channel())
    }
    await server.releaseFirstBegin()

    #expect(try await first.value.tuple == firstRequest.tuple)
    #expect(try await newest.value.tuple == newestRequest.tuple)
    let status = await server.status()
    #expect(status.persistedGeneration == newestRequest.tuple.generation)
    #expect(status.begunGenerations == [7, 8])
    #expect(!status.hasStaging)
}

enum LostReplyPoint: String, CaseIterable, Sendable {
    case begin
    case chunk
    case finish
}

private enum FakeTransferError: Error, Equatable {
    case lostReply
    case busy
    case invalidOffset
    case incomplete
}

private struct FakeTransferStatus: Sendable {
    let persistedGeneration: UInt64?
    let abortCount: Int
    let hasStaging: Bool
    let begunGenerations: [UInt64]
}

private actor FakeTransferServer {
    private struct Staging {
        let header: SnapshotTransferBegin
        var bytes = Data()
    }

    private var lostReplyAt: LostReplyPoint?
    private var staging: Staging?
    private var persisted: PolicyTuple?
    private var abortCount = 0
    private var begunGenerations: [UInt64] = []
    private var pauseFirstBegin: Bool
    private var firstBeginIsPaused = false
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private let providerEpoch = UUID()

    init(lostReplyAt: LostReplyPoint? = nil, pauseFirstBegin: Bool = false) {
        self.lostReplyAt = lostReplyAt
        self.pauseFirstBegin = pauseFirstBegin
    }

    nonisolated func channel() -> SnapshotTransferChannel {
        SnapshotTransferChannel(
            begin: { try await self.begin($0) },
            append: { try await self.append($0) },
            finish: { try await self.finish() },
            abort: { await self.abort() }
        )
    }

    func begin(_ header: SnapshotTransferBegin) async throws {
        guard staging == nil else { throw FakeTransferError.busy }
        staging = Staging(header: header)
        begunGenerations.append(header.generation)
        if lostReplyAt == .begin {
            lostReplyAt = nil
            throw FakeTransferError.lostReply
        }
        if pauseFirstBegin {
            pauseFirstBegin = false
            firstBeginIsPaused = true
            let observers = pauseObservers
            pauseObservers = []
            observers.forEach { $0.resume() }
            await withCheckedContinuation { releaseContinuation = $0 }
            firstBeginIsPaused = false
        }
    }

    func append(_ chunk: SnapshotChunk) throws {
        guard var current = staging,
              chunk.offset == current.bytes.count else {
            throw FakeTransferError.invalidOffset
        }
        current.bytes.append(chunk.bytes)
        staging = current
        if lostReplyAt == .chunk {
            lostReplyAt = nil
            throw FakeTransferError.lostReply
        }
    }

    func finish() throws -> SnapshotFinishResult {
        guard let current = staging,
              current.bytes.count == current.header.byteCount else {
            throw FakeTransferError.incomplete
        }
        let tuple = PolicyTuple(
            lineageID: current.header.lineageID,
            generation: current.header.generation,
            hash: current.header.hash
        )
        staging = nil
        persisted = tuple
        if lostReplyAt == .finish {
            lostReplyAt = nil
            throw FakeTransferError.lostReply
        }
        return SnapshotFinishResult(
            disposition: .active,
            tuple: tuple,
            providerEpoch: providerEpoch
        )
    }

    func abort() {
        abortCount += 1
        staging = nil
    }

    func waitUntilFirstBeginIsPaused() async {
        guard !firstBeginIsPaused else { return }
        await withCheckedContinuation { pauseObservers.append($0) }
    }

    func releaseFirstBegin() {
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }

    func status() -> FakeTransferStatus {
        FakeTransferStatus(
            persistedGeneration: persisted?.generation,
            abortCount: abortCount,
            hasStaging: staging != nil,
            begunGenerations: begunGenerations
        )
    }
}

private func transferRequest(lineageID: UUID, generation: UInt64) -> SnapshotTransferRequest {
    SnapshotTransferRequest(
        tuple: PolicyTuple(
            lineageID: lineageID,
            generation: generation,
            hash: Data(repeating: UInt8(truncatingIfNeeded: generation), count: 32)
        ),
        schemaVersion: 1,
        bytes: Data(repeating: UInt8(truncatingIfNeeded: generation), count: 64)
    )
}
