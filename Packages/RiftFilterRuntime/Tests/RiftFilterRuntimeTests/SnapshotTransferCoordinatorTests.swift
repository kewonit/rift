import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftFilterRuntime

@Test func transferRequiresSequentialBoundedChunks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RootPolicyStore(rootURL: root)
    let lineage = UUID()
    try await store.claim(uid: 501, lineageID: lineage)
    let artifact = try PolicyArtifact.compile(CompiledPolicyPayload(
        lineageID: lineage, generation: 1, authorizedUID: 501,
        createdAt: Date(timeIntervalSince1970: 1), operationMode: .alert,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: []
    ))
    let transfer = SnapshotTransferCoordinator(store: store)
    let now = Date(timeIntervalSince1970: 10)
    try await transfer.begin(SnapshotTransferBegin(
        lineageID: lineage,
        generation: 1,
        schemaVersion: CompiledPolicyPayload.currentSchemaVersion,
        byteCount: artifact.bytes.count,
        hash: artifact.hash
    ), now: now)
    let midpoint = artifact.bytes.count / 2
    try await transfer.append(offset: 0, chunk: artifact.bytes.prefix(midpoint), now: now)
    await #expect(throws: SnapshotTransferError.invalidOffset(expected: midpoint, received: 0)) {
        try await transfer.append(offset: 0, chunk: Data([0]), now: now)
    }
    try await transfer.append(
        offset: midpoint,
        chunk: artifact.bytes.suffix(from: midpoint),
        now: now
    )
    let result = try await transfer.finish(now: now)
    #expect(result.tuple.generation == 1)
}

@Test func transferRejectsPolicyThatRequiresANewerExtensionProtocol() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RootPolicyStore(rootURL: root)
    let lineage = UUID()
    try await store.claim(uid: 501, lineageID: lineage)
    let artifact = try PolicyArtifact.compile(CompiledPolicyPayload(
        lineageID: lineage,
        generation: 1,
        authorizedUID: 501,
        compatibility: PolicyCompatibility(
            minimumExtensionProtocol: ProtocolVersion(
                major: ProtocolVersion.current.major,
                minor: ProtocolVersion.current.minor + 1
            )
        ),
        createdAt: Date(timeIntervalSince1970: 1),
        operationMode: .alert,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: []
    ))
    let transfer = SnapshotTransferCoordinator(store: store)
    let now = Date(timeIntervalSince1970: 10)
    try await transfer.begin(SnapshotTransferBegin(
        lineageID: lineage,
        generation: 1,
        schemaVersion: CompiledPolicyPayload.currentSchemaVersion,
        byteCount: artifact.bytes.count,
        hash: artifact.hash
    ), now: now)
    try await transfer.append(offset: 0, chunk: artifact.bytes, now: now)

    await #expect(throws: SnapshotTransferError.incompatibleProtocol) {
        _ = try await transfer.finish(now: now)
    }
}

@Test func transferDeadlineDestroysStaging() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RootPolicyStore(rootURL: root)
    let transfer = SnapshotTransferCoordinator(store: store)
    let now = Date(timeIntervalSince1970: 10)
    try await transfer.begin(SnapshotTransferBegin(
        lineageID: UUID(), generation: 1,
        schemaVersion: CompiledPolicyPayload.currentSchemaVersion,
        byteCount: 1, hash: Data(repeating: 0, count: 32)
    ), now: now)
    await #expect(throws: SnapshotTransferError.deadlineExceeded) {
        try await transfer.append(
            offset: 0,
            chunk: Data([0]),
            now: now.addingTimeInterval(IPCProtocolLimits.transferDeadlineSeconds + 1)
        )
    }
    #expect(await !transfer.hasStagingTransfer())
}

@Test func expiredStagingDoesNotBlockANewBegin() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RootPolicyStore(rootURL: root)
    let transfer = SnapshotTransferCoordinator(store: store)
    let now = Date(timeIntervalSince1970: 10)
    try await transfer.begin(SnapshotTransferBegin(
        lineageID: UUID(), generation: 1,
        schemaVersion: CompiledPolicyPayload.currentSchemaVersion,
        byteCount: 1, hash: Data(repeating: 0, count: 32)
    ), now: now)

    let replacement = SnapshotTransferBegin(
        lineageID: UUID(), generation: 2,
        schemaVersion: CompiledPolicyPayload.currentSchemaVersion,
        byteCount: 1, hash: Data(repeating: 1, count: 32)
    )
    await #expect(throws: SnapshotTransferError.transferBusy) {
        try await transfer.begin(
            replacement,
            now: now.addingTimeInterval(IPCProtocolLimits.transferDeadlineSeconds)
        )
    }
    try await transfer.begin(
        replacement,
        now: now.addingTimeInterval(IPCProtocolLimits.transferDeadlineSeconds + 1)
    )

    #expect(await transfer.hasStagingTransfer())
}
