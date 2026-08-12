import AbyssIPC
import Foundation
import Testing
@testable import AbyssControl

@Test func configurationRecoveryOwnedRootUsesDisclosedLineage() async throws {
    let connectionID = UUID()
    let lineageID = UUID()
    let tuple = recoveryTuple(lineageID: lineageID, generation: 4, byte: 1)
    let probe = RecoveryUninstallProbe(
        connectionID: connectionID,
        handshake: recoveryHandshake(
            providerEpoch: UUID(),
            readiness: .ready,
            boundLineageID: lineageID,
            highWater: 4,
            persisted: tuple,
            active: tuple
        )
    )

    try await runRecoveryUninstall(probe: probe, fallbackLineageID: UUID())

    #expect(await probe.operations() == [
        .connect(connectionID),
        .handshake,
        .requireCurrent(connectionID),
        .claim(lineageID, connectionID),
        .requireCurrent(connectionID),
        .prepareUninstall,
    ])
}

@Test func configurationRecoveryInterruptedResetUsesOpaqueLineage() async throws {
    let connectionID = UUID()
    let fallbackLineageID = UUID()
    let probe = RecoveryUninstallProbe(
        connectionID: connectionID,
        handshake: recoveryHandshake(readiness: .degradedNoPolicy)
    )

    try await runRecoveryUninstall(
        probe: probe,
        fallbackLineageID: fallbackLineageID
    )

    #expect(await probe.operations().contains(.claim(fallbackLineageID, connectionID)))
    #expect(await probe.prepareCount() == 1)
}

@Test func configurationRecoveryForeignUndisclosedRootFailsClosed() async {
    let probe = RecoveryUninstallProbe(
        connectionID: UUID(),
        handshake: recoveryHandshake(providerEpoch: UUID(), readiness: .ready),
        claimFailure: .foreignOwner
    )

    await #expect(throws: RecoveryUninstallProbeError.foreignOwner) {
        try await runRecoveryUninstall(probe: probe, fallbackLineageID: UUID())
    }
    #expect(await probe.prepareCount() == 0)
}

@Test func configurationRecoveryUnavailableUndisclosedRootFailsClosed() async {
    let probe = RecoveryUninstallProbe(
        connectionID: UUID(),
        handshake: recoveryHandshake(readiness: .degradedPersistence),
        claimFailure: .persistenceUnavailable
    )

    await #expect(throws: RecoveryUninstallProbeError.persistenceUnavailable) {
        try await runRecoveryUninstall(probe: probe, fallbackLineageID: UUID())
    }
    #expect(await probe.prepareCount() == 0)
}

@Test func configurationRecoveryRejectsInconsistentRootBeforeClaim() async {
    let disclosedLineageID = UUID()
    let otherLineageID = UUID()
    let probe = RecoveryUninstallProbe(
        connectionID: UUID(),
        handshake: recoveryHandshake(
            readiness: .ready,
            boundLineageID: disclosedLineageID,
            highWater: 3,
            persisted: recoveryTuple(
                lineageID: otherLineageID,
                generation: 3,
                byte: 2
            )
        )
    )

    await #expect(throws: ConfigurationRecoveryUninstallError.inconsistentRootState) {
        try await runRecoveryUninstall(probe: probe, fallbackLineageID: UUID())
    }
    #expect(await probe.claimCount() == 0)
    #expect(await probe.prepareCount() == 0)
}

@Test func configurationRecoveryRejectsMismatchedConfigurationResetEvidence() async {
    let probe = RecoveryUninstallProbe(
        connectionID: UUID(),
        handshake: recoveryHandshake(
            readiness: .degradedNoPolicy,
            boundLineageID: UUID(),
            configurationResetLineageID: UUID()
        )
    )
    await #expect(throws: ConfigurationRecoveryUninstallError.inconsistentRootState) {
        try await runRecoveryUninstall(probe: probe, fallbackLineageID: UUID())
    }
    #expect(await probe.claimCount() == 0)
    #expect(await probe.prepareCount() == 0)
}

@Test func configurationRecoveryStopsAfterConnectionReplacement() async {
    let originalConnectionID = UUID()
    let replacementConnectionID = UUID()
    let lineageID = UUID()
    let probe = RecoveryUninstallProbe(
        connectionID: originalConnectionID,
        handshake: recoveryHandshake(
            readiness: .ready,
            boundLineageID: lineageID
        ),
        replacementConnectionIDAfterClaim: replacementConnectionID
    )

    await #expect(throws: RecoveryUninstallProbeError.staleConnection) {
        try await runRecoveryUninstall(probe: probe, fallbackLineageID: UUID())
    }
    #expect(await probe.claimCount() == 1)
    #expect(await probe.prepareCount() == 0)
}

@Test func configurationRecoveryCancellationAfterClaimNeverPreparesUninstall() async {
    let connectionID = UUID()
    let lineageID = UUID()
    let claimGate = RecoveryClaimGate()
    let prepareCounter = RecoveryPrepareCounter()
    let handshake = recoveryHandshake(
        readiness: .ready,
        boundLineageID: lineageID
    )
    let task = Task {
        try await ConfigurationRecoveryUninstall.prepare(
            undisclosedLineageID: UUID(),
            connect: { connectionID },
            handshake: { handshake },
            requireCurrentConnection: { _ in },
            claimController: { _, _ in await claimGate.pauseClaim() },
            prepareUninstall: { await prepareCounter.record() }
        )
    }

    await claimGate.waitUntilClaimStarted()
    task.cancel()
    await claimGate.releaseClaim()

    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await prepareCounter.count() == 0)
}

private func runRecoveryUninstall(
    probe: RecoveryUninstallProbe,
    fallbackLineageID: UUID
) async throws {
    try await ConfigurationRecoveryUninstall.prepare(
        undisclosedLineageID: fallbackLineageID,
        connect: { try await probe.connect() },
        handshake: { try await probe.readHandshake() },
        requireCurrentConnection: { try await probe.requireCurrentConnection($0) },
        claimController: { try await probe.claim(lineageID: $0, connectionID: $1) },
        prepareUninstall: { try await probe.prepareUninstall() }
    )
}

private enum RecoveryUninstallOperation: Sendable, Equatable {
    case connect(UUID)
    case handshake
    case requireCurrent(UUID)
    case claim(UUID, UUID)
    case prepareUninstall
}

private enum RecoveryUninstallProbeError: Error, Sendable, Equatable {
    case foreignOwner
    case persistenceUnavailable
    case staleConnection
}

private actor RecoveryUninstallProbe {
    private let connectionID: UUID
    private let handshakeValue: HandshakeState
    private let claimFailure: RecoveryUninstallProbeError?
    private let replacementConnectionIDAfterClaim: UUID?
    private var currentConnectionID: UUID
    private var recordedOperations: [RecoveryUninstallOperation] = []

    init(
        connectionID: UUID,
        handshake: HandshakeState,
        claimFailure: RecoveryUninstallProbeError? = nil,
        replacementConnectionIDAfterClaim: UUID? = nil
    ) {
        self.connectionID = connectionID
        self.handshakeValue = handshake
        self.claimFailure = claimFailure
        self.replacementConnectionIDAfterClaim = replacementConnectionIDAfterClaim
        self.currentConnectionID = connectionID
    }

    func connect() throws -> UUID {
        recordedOperations.append(.connect(connectionID))
        return connectionID
    }

    func readHandshake() throws -> HandshakeState {
        recordedOperations.append(.handshake)
        return handshakeValue
    }

    func requireCurrentConnection(_ expectedID: UUID) throws {
        recordedOperations.append(.requireCurrent(expectedID))
        guard currentConnectionID == expectedID else {
            throw RecoveryUninstallProbeError.staleConnection
        }
    }

    func claim(lineageID: UUID, connectionID: UUID) throws {
        recordedOperations.append(.claim(lineageID, connectionID))
        if let claimFailure { throw claimFailure }
        if let replacementConnectionIDAfterClaim {
            currentConnectionID = replacementConnectionIDAfterClaim
        }
    }

    func prepareUninstall() throws {
        recordedOperations.append(.prepareUninstall)
    }

    func operations() -> [RecoveryUninstallOperation] { recordedOperations }
    func claimCount() -> Int { recordedOperations.filter { if case .claim = $0 { true } else { false } }.count }
    func prepareCount() -> Int { recordedOperations.filter { $0 == .prepareUninstall }.count }
}

private actor RecoveryClaimGate {
    private var claimStarted = false
    private var claimReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseClaim() async {
        claimStarted = true
        let pendingStartWaiters = startWaiters
        startWaiters.removeAll()
        for waiter in pendingStartWaiters { waiter.resume() }
        guard !claimReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilClaimStarted() async {
        guard !claimStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func releaseClaim() {
        claimReleased = true
        let pendingReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in pendingReleaseWaiters { waiter.resume() }
    }
}

private actor RecoveryPrepareCounter {
    private var value = 0
    func record() { value += 1 }
    func count() -> Int { value }
}

private func recoveryHandshake(
    providerEpoch: UUID? = nil,
    readiness: ProviderReadiness,
    boundLineageID: UUID? = nil,
    configurationResetLineageID: UUID? = nil,
    highWater: UInt64 = 0,
    persisted: PolicyTuple? = nil,
    active: PolicyTuple? = nil,
    controllerLeaseID: UUID? = nil
) -> HandshakeState {
    HandshakeState(
        runtimeInstanceID: UUID(),
        providerEpoch: providerEpoch,
        readiness: readiness,
        protocolRange: ProtocolRange(minimum: .current, maximum: .current),
        snapshotSchemaRange: 1...1,
        acceptedGenerationHighWater: highWater,
        boundLineageID: boundLineageID,
        configurationResetLineageID: configurationResetLineageID,
        persisted: persisted,
        active: active,
        controllerLeaseID: controllerLeaseID
    )
}

private func recoveryTuple(
    lineageID: UUID,
    generation: UInt64,
    byte: UInt8
) -> PolicyTuple {
    PolicyTuple(
        lineageID: lineageID,
        generation: generation,
        hash: Data(repeating: byte, count: 32)
    )
}
