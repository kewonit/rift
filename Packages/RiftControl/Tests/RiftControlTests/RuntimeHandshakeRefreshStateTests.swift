import RiftIPC
import Foundation
import Testing
@testable import RiftControl

@Test func runtimeRefreshClearsReadyEvidenceUntilStoppedStateArrives() {
    let active = refreshTuple()
    var state = RuntimeHandshakeRefreshState(
        presentedHandshake: refreshHandshake(
            readiness: .ready,
            providerEpoch: UUID(),
            active: active
        )
    )

    let shouldRefresh = state.signal()
    #expect(shouldRefresh)
    #expect(state.presentedHandshake == nil)
    let shouldRefreshAgain = state.complete(with: refreshHandshake(
        readiness: .unavailable,
        providerEpoch: nil,
        active: nil
    ))
    #expect(!shouldRefreshAgain)
    #expect(state.presentedHandshake?.readiness == .unavailable)
    #expect(state.presentedHandshake?.providerEpoch == nil)
    #expect(state.presentedHandshake?.active == nil)
}

@Test func runtimeRefreshPresentsCompletedDegradedNoPolicyState() {
    var state = RuntimeHandshakeRefreshState(
        presentedHandshake: refreshHandshake(
            readiness: .ready,
            providerEpoch: UUID(),
            active: refreshTuple()
        )
    )
    let epoch = UUID()

    let shouldRefresh = state.signal()
    #expect(shouldRefresh)
    let shouldRefreshAgain = state.complete(with: refreshHandshake(
        readiness: .degradedNoPolicy,
        providerEpoch: epoch,
        active: nil
    ))
    #expect(!shouldRefreshAgain)
    #expect(state.presentedHandshake?.readiness == .degradedNoPolicy)
    #expect(state.presentedHandshake?.providerEpoch == epoch)
    #expect(state.presentedHandshake?.active == nil)
}

@Test func duplicateRuntimeSignalsCoalesceAndDiscardIntermediateHandshake() {
    let ready = refreshHandshake(
        readiness: .ready,
        providerEpoch: UUID(),
        active: refreshTuple()
    )
    var state = RuntimeHandshakeRefreshState(presentedHandshake: ready)

    let shouldRefresh = state.signal()
    let duplicateShouldRefresh = state.signal()
    let shouldRefreshAgain = state.complete(with: ready)
    #expect(shouldRefresh)
    #expect(!duplicateShouldRefresh)
    #expect(shouldRefreshAgain)
    #expect(state.presentedHandshake == nil)

    let stopped = refreshHandshake(readiness: .unavailable, providerEpoch: nil, active: nil)
    let settled = state.complete(with: stopped)
    #expect(!settled)
    #expect(state.presentedHandshake == stopped)
}

private func refreshTuple() -> PolicyTuple {
    PolicyTuple(lineageID: UUID(), generation: 4, hash: Data(repeating: 4, count: 32))
}

private func refreshHandshake(
    readiness: ProviderReadiness,
    providerEpoch: UUID?,
    active: PolicyTuple?
) -> HandshakeState {
    HandshakeState(
        runtimeInstanceID: UUID(),
        providerEpoch: providerEpoch,
        readiness: readiness,
        protocolRange: ProtocolRange(minimum: .current, maximum: .current),
        snapshotSchemaRange: 1...1,
        acceptedGenerationHighWater: active?.generation ?? 0,
        boundLineageID: active?.lineageID,
        persisted: active,
        active: active,
        controllerLeaseID: active == nil ? nil : UUID()
    )
}
