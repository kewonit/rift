import Foundation
import Testing
@testable import AbyssFilterRuntime

@Test func firstOwnerClaimBeforeProviderStartIsRejectedAndRemainsUnclaimed() async throws {
    let fixture = try FirstOwnerStoreFixture()
    defer { fixture.remove() }
    let state = ProviderPersistenceState()
    let ownership = try await fixture.store.initializeIfNeeded()

    #expect(throws: ControllerClaimAuthorizationError.initialClaimRequiresActiveProvider) {
        _ = try ControllerClaimGate.authorize(
            ownership: ownership,
            uid: 501,
            lineageID: UUID(),
            providerEpoch: nil,
            persistenceState: state
        )
    }
    #expect(try await fixture.store.ownership() == .unclaimed)
}

@Test func firstOwnerClaimWhileProviderIsStartingIsRejected() {
    var state = ProviderPersistenceState()
    state.beginProviderStart(
        rootPersistenceAvailable: true,
        tombstonePersistenceAvailable: true
    )
    #expect(state.readiness == .starting)
    expectInitialClaimRejected(state: state, providerEpoch: UUID())
}

@Test func firstOwnerClaimAfterSettingsFailureIsRejected() {
    var state = ProviderPersistenceState()
    state.beginProviderStart(
        rootPersistenceAvailable: true,
        tombstonePersistenceAvailable: true
    )
    #expect(state.completeProviderStart(settingsSucceeded: false, hasActivePolicy: false)
        == .unavailable)
    expectInitialClaimRejected(state: state, providerEpoch: UUID())
}

@Test func firstOwnerClaimAfterCompletedDegradedNoPolicyStartIsPermitted() throws {
    var state = ProviderPersistenceState()
    state.beginProviderStart(
        rootPersistenceAvailable: true,
        tombstonePersistenceAvailable: true
    )
    #expect(state.completeProviderStart(settingsSucceeded: true, hasActivePolicy: false)
        == .degradedNoPolicy)
    #expect(try ControllerClaimGate.authorize(
        ownership: .unclaimed,
        uid: 501,
        lineageID: UUID(),
        providerEpoch: UUID(),
        persistenceState: state
    ) == .claimFirstOwner)
}

@Test func firstOwnerClaimAfterProviderStopIsRejected() {
    var state = ProviderPersistenceState()
    state.beginProviderStart(
        rootPersistenceAvailable: true,
        tombstonePersistenceAvailable: true
    )
    _ = state.completeProviderStart(settingsSucceeded: true, hasActivePolicy: false)
    state.stopProvider()
    expectInitialClaimRejected(state: state, providerEpoch: nil)
}

@Test func existingOwnerCanReconnectWithoutProvider() throws {
    let lineage = UUID()
    #expect(try ControllerClaimGate.authorize(
        ownership: .owned(
            uid: 501,
            lineageID: lineage,
            acceptedGenerationHighWater: 7
        ),
        uid: 501,
        lineageID: lineage,
        providerEpoch: nil,
        persistenceState: ProviderPersistenceState()
    ) == .reconnectExistingOwner)
}

@Test func foreignOwnerIsRejectedEvenWhenProviderCanActivate() {
    var state = ProviderPersistenceState()
    state.beginProviderStart(
        rootPersistenceAvailable: true,
        tombstonePersistenceAvailable: true
    )
    _ = state.completeProviderStart(settingsSucceeded: true, hasActivePolicy: false)
    #expect(throws: ControllerClaimAuthorizationError.foreignOwner) {
        _ = try ControllerClaimGate.authorize(
            ownership: .owned(
                uid: 502,
                lineageID: UUID(),
                acceptedGenerationHighWater: 0
            ),
            uid: 501,
            lineageID: UUID(),
            providerEpoch: UUID(),
            persistenceState: state
        )
    }
}

@Test func interruptedVerifiedUninstallCanOnlyBeResumedByItsOldOwner() async throws {
    let fixture = try FirstOwnerStoreFixture()
    defer { fixture.remove() }
    let originalLineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: originalLineage)
    try await fixture.store.beginVerifiedUninstall(uid: 501)
    let resetting = try await fixture.store.ownership()

    #expect(try ControllerClaimGate.authorize(
        ownership: resetting,
        uid: 501,
        lineageID: UUID(),
        providerEpoch: nil,
        persistenceState: ProviderPersistenceState()
    ) == .resumeVerifiedUninstall)
    #expect(try await fixture.store.ownership() == resetting)
    #expect(throws: ControllerClaimAuthorizationError.foreignOwner) {
        _ = try ControllerClaimGate.authorize(
            ownership: resetting,
            uid: 502,
            lineageID: originalLineage,
            providerEpoch: nil,
            persistenceState: ProviderPersistenceState()
        )
    }
}

@Test func interruptedConfigurationResetRequiresOldOwnerAndExactTargetLineage() throws {
    let target = UUID()
    let resetting = RootOwnership.replacingConfiguration(
        oldUID: 501,
        targetLineageID: target
    )
    #expect(try ControllerClaimGate.authorize(
        ownership: resetting,
        uid: 501,
        lineageID: target,
        providerEpoch: nil,
        persistenceState: ProviderPersistenceState()
    ) == .resumeConfigurationReset(targetLineageID: target))
    #expect(throws: ControllerClaimAuthorizationError.lineageMismatch) {
        _ = try ControllerClaimGate.authorize(
            ownership: resetting,
            uid: 501,
            lineageID: UUID(),
            providerEpoch: nil,
            persistenceState: ProviderPersistenceState()
        )
    }
    #expect(throws: ControllerClaimAuthorizationError.foreignOwner) {
        _ = try ControllerClaimGate.authorize(
            ownership: resetting,
            uid: 502,
            lineageID: target,
            providerEpoch: nil,
            persistenceState: ProviderPersistenceState()
        )
    }
}

private func expectInitialClaimRejected(
    state: ProviderPersistenceState,
    providerEpoch: UUID?
) {
    #expect(throws: ControllerClaimAuthorizationError.initialClaimRequiresActiveProvider) {
        _ = try ControllerClaimGate.authorize(
            ownership: .unclaimed,
            uid: 501,
            lineageID: UUID(),
            providerEpoch: providerEpoch,
            persistenceState: state
        )
    }
}

private struct FirstOwnerStoreFixture {
    let root: URL
    let store: RootPolicyStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try RootPolicyStore(rootURL: root)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
