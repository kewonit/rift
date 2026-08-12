import AbyssCore
import AbyssIPC
import Foundation
import Testing
@testable import AbyssFilterRuntime

@Test func storeClaimsPromotesAndRecoversNewestPolicy() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let lineage = UUID()
    #expect(try await fixture.store.initializeIfNeeded() == .unclaimed)
    try await fixture.store.claim(uid: 501, lineageID: lineage)

    let first = try fixture.artifact(lineage: lineage, generation: 1)
    let promoted = try await fixture.store.promote(first)
    let recovered = try await fixture.store.recoverNewest()
    #expect(promoted.tuple == recovered.tuple)
    #expect(recovered.payload.authorizedUID == 501)
}

@Test func storeRejectsSameGenerationWithDifferentHash() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let lineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: lineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: lineage, generation: 1))
    let changed = try fixture.artifact(
        lineage: lineage,
        generation: 1,
        mode: .silentDeny
    )
    await #expect(throws: RootPolicyStoreError.generationHashMismatch) {
        _ = try await fixture.store.promote(changed)
    }
}

@Test func recoveryRaisesHighWaterAfterLostAcknowledgement() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let lineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: lineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: lineage, generation: 1))

    let second = try fixture.artifact(lineage: lineage, generation: 2)
    let payload = try second.decode()
    let slot = PolicySlot(ownerUID: 501, artifact: second, payload: payload)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try fixture.directory.writeAtomically(try encoder.encode(slot), to: "policy-b.slot")

    let recovered = try await fixture.store.recoverNewest()
    #expect(recovered.tuple.generation == 2)
    #expect(recovered.recoveredAfterLostAcknowledgement)
    #expect(try await fixture.store.ownership() == .owned(
        uid: 501,
        lineageID: lineage,
        acceptedGenerationHighWater: 2
    ))
}

@Test func recoveryFallsBackFromNewerProtocolToPreviousCompatibleSlot() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let lineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: lineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: lineage, generation: 1))

    let futureArtifact = try fixture.artifact(
        lineage: lineage,
        generation: 2,
        compatibility: PolicyCompatibility(
            minimumExtensionProtocol: ProtocolVersion(
                major: ProtocolVersion.current.major,
                minor: ProtocolVersion.current.minor + 1
            )
        )
    )
    await #expect(throws: RootPolicyStoreError.incompatibleProtocol) {
        _ = try await fixture.store.promote(futureArtifact)
    }
    _ = try await fixture.store.promote(fixture.artifact(lineage: lineage, generation: 2))
    let slot = PolicySlot(
        ownerUID: 501,
        artifact: futureArtifact,
        payload: try futureArtifact.decode()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    try fixture.directory.writeAtomically(try encoder.encode(slot), to: "policy-b.slot")

    let recovered = try await fixture.store.recoverNewest()
    #expect(recovered.tuple.generation == 1)
    #expect(try await fixture.store.ownership() == .owned(
        uid: 501,
        lineageID: lineage,
        acceptedGenerationHighWater: 2
    ))
}

@Test func existingEmptyStoreNeverBecomesFreshUnclaimedState() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RootPolicyStore(rootURL: root)
    await #expect(throws: RootPolicyStoreError.corruptOwnership) {
        _ = try await store.initializeIfNeeded()
    }
}

@Test func deletedOwnershipIsNotRecreatedAsFreshByALiveStore() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    #expect(try await fixture.store.initializeIfNeeded() == .unclaimed)
    try fixture.directory.remove("ownership.json")

    await #expect(throws: RootPolicyStoreError.corruptOwnership) {
        _ = try await fixture.store.initializeIfNeeded()
    }
}

@Test func verifiedUninstallIsTwoPhaseRetryableAndEndsUnclaimed() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let lineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: lineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: lineage, generation: 1))

    try await fixture.store.beginVerifiedUninstall(uid: 501)
    guard case .resetting(let oldUID, _) = try await fixture.store.ownership() else {
        Issue.record("Expected resetting ownership")
        return
    }
    #expect(oldUID == 501)
    try await fixture.store.beginVerifiedUninstall(uid: 501)
    try await fixture.store.erasePolicyArtifactsForVerifiedUninstall(uid: 501)
    try await fixture.store.erasePolicyArtifactsForVerifiedUninstall(uid: 501)
    try await fixture.store.finishVerifiedUninstall(uid: 501)
    #expect(try await fixture.store.ownership() == .unclaimed)
    try await fixture.store.finishVerifiedUninstall(uid: 501)
}

@Test func configurationResetNeverPassesThroughUnclaimedAndAcceptsOnlyNewGenerationOne() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let oldLineage = UUID()
    let targetLineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: oldLineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: oldLineage, generation: 4))

    try await fixture.store.beginConfigurationReset(uid: 501, targetLineageID: targetLineage)
    #expect(try await fixture.store.ownership() == .replacingConfiguration(
        oldUID: 501,
        targetLineageID: targetLineage
    ))
    await #expect(throws: RootPolicyStoreError.mutationLocked) {
        _ = try await fixture.store.recoverNewest()
    }
    try await fixture.store.erasePolicyArtifactsForConfigurationReset(
        uid: 501,
        targetLineageID: targetLineage
    )
    await #expect(throws: RootPolicyStoreError.lineageMismatch) {
        _ = try await fixture.store.promote(
            fixture.artifact(lineage: oldLineage, generation: 1)
        )
    }
    await #expect(throws: RootPolicyStoreError.staleGeneration) {
        _ = try await fixture.store.promote(
            fixture.artifact(lineage: targetLineage, generation: 2)
        )
    }

    let recovered = try await fixture.store.promote(
        fixture.artifact(lineage: targetLineage, generation: 1)
    )
    #expect(recovered.tuple.generation == 1)
    #expect(try await fixture.store.ownership() == .owned(
        uid: 501,
        lineageID: targetLineage,
        acceptedGenerationHighWater: 1
    ))
}

@Test func interruptedConfigurationResetPromotionIsFailOpenAndRetryable() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let oldLineage = UUID()
    let targetLineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: oldLineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: oldLineage, generation: 1))
    try await fixture.store.beginConfigurationReset(uid: 501, targetLineageID: targetLineage)
    try await fixture.store.erasePolicyArtifactsForConfigurationReset(
        uid: 501,
        targetLineageID: targetLineage
    )
    let faulted = try RootPolicyStore(rootURL: fixture.root) { checkpoint in
        if checkpoint == .beforeSlotReopen(target: "policy-a.slot") {
            throw InjectedPromotionFailure.stop
        }
    }
    await #expect(throws: InjectedPromotionFailure.stop) {
        _ = try await faulted.promote(
            fixture.artifact(lineage: targetLineage, generation: 1)
        )
    }
    #expect(try await fixture.store.ownership() == .replacingConfiguration(
        oldUID: 501,
        targetLineageID: targetLineage
    ))
    await #expect(throws: RootPolicyStoreError.mutationLocked) {
        _ = try await fixture.store.recoverNewest()
    }

    try await fixture.store.beginConfigurationReset(uid: 501, targetLineageID: targetLineage)
    try await fixture.store.erasePolicyArtifactsForConfigurationReset(
        uid: 501,
        targetLineageID: targetLineage
    )
    _ = try await fixture.store.promote(
        fixture.artifact(lineage: targetLineage, generation: 1)
    )
    #expect(try await fixture.store.recoverNewest().tuple.lineageID == targetLineage)
}

@Test func configurationResetCanStillExitThroughVerifiedOwnerUninstall() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let oldLineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: oldLineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: oldLineage, generation: 1))
    try await fixture.store.beginConfigurationReset(uid: 501, targetLineageID: UUID())

    try await fixture.store.beginVerifiedUninstall(uid: 501)
    guard case .resetting(let oldUID, _) = try await fixture.store.ownership() else {
        Issue.record("Expected verified uninstall state")
        return
    }
    #expect(oldUID == 501)
    try await fixture.store.erasePolicyArtifactsForVerifiedUninstall(uid: 501)
    try await fixture.store.finishVerifiedUninstall(uid: 501)
    #expect(try await fixture.store.ownership() == .unclaimed)
}

@Test func staleLegacyTemporaryArtifactDoesNotBlockAtomicWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let directory = try SecureDirectory(url: root)
    defer { try? FileManager.default.removeItem(at: root) }
    let staleURL = root.appendingPathComponent(".tmp-(UUID().uuidString.lowercased())")
    try Data("stale".utf8).write(to: staleURL)

    let expected = Data("current".utf8)
    try directory.writeAtomically(expected, to: "expiry-tombstones.json")

    #expect(try directory.read("expiry-tombstones.json", maximumBytes: 1_024) == expected)
    #expect(FileManager.default.fileExists(atPath: staleURL.path))
}

@Test func concurrentStorePromotionsRetainTheHighestGeneration() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let lineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: lineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: lineage, generation: 1))
    let otherStore = try RootPolicyStore(rootURL: fixture.root)
    let second = try fixture.artifact(lineage: lineage, generation: 2)
    let third = try fixture.artifact(lineage: lineage, generation: 3)

    async let lower = promotionOutcome(store: fixture.store, artifact: second)
    async let higher = promotionOutcome(store: otherStore, artifact: third)
    let outcomes = await (lower, higher)

    #expect(outcomes.0 != .failed)
    #expect(outcomes.1 == .promoted(3))
    #expect(try await fixture.store.recoverNewest().tuple.generation == 3)
}

@Test func missingIndexCannotSelectTheSoleValidSlotForOverwrite() async throws {
    try await assertIndexDamagePreservesLastKnownGood(.missing)
}

@Test func corruptIndexCannotSelectTheSoleValidSlotForOverwrite() async throws {
    try await assertIndexDamagePreservesLastKnownGood(.corrupt)
}

@Test func staleIndexCannotSelectTheSoleValidSlotForOverwrite() async throws {
    try await assertIndexDamagePreservesLastKnownGood(.stale)
}

@Test func claimRejectsAResidualCorruptFixedSlot() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.store.initializeIfNeeded()
    try fixture.directory.writeAtomically(Data("not-a-slot".utf8), to: "policy-a.slot")

    await #expect(throws: RootPolicyStoreError.residualSlotsWhileUnclaimed) {
        try await fixture.store.claim(uid: 501, lineageID: UUID())
    }
}

@Test func operationalSlotReadFailureIsNotDowngradedToCorruption() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    _ = try await fixture.store.initializeIfNeeded()
    try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent("policy-a.slot"),
        withIntermediateDirectories: false
    )

    await #expect(throws: SecureDirectoryError.notRegularFile) {
        try await fixture.store.claim(uid: 501, lineageID: UUID())
    }
}

@Test func reopenFailureKeepsThePreviousSlotAndLeavesTheNewSlotRecoverable() async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let lineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: lineage)
    _ = try await fixture.store.promote(fixture.artifact(lineage: lineage, generation: 1))
    let faultedStore = try RootPolicyStore(rootURL: fixture.root) { checkpoint in
        if checkpoint == .beforeSlotReopen(target: "policy-b.slot") {
            throw InjectedPromotionFailure.stop
        }
    }

    await #expect(throws: InjectedPromotionFailure.stop) {
        _ = try await faultedStore.promote(fixture.artifact(lineage: lineage, generation: 2))
    }

    #expect(try fixture.slotGeneration(named: "policy-a.slot") == 1)
    #expect(try fixture.slotGeneration(named: "policy-b.slot") == 2)
    let recovered = try await fixture.store.recoverNewest()
    #expect(recovered.tuple.generation == 2)
    #expect(recovered.recoveredAfterLostAcknowledgement)
}

private enum IndexDamage {
    case missing
    case corrupt
    case stale
}

private enum InjectedPromotionFailure: Error, Equatable {
    case stop
}

private enum PromotionOutcome: Sendable, Equatable {
    case promoted(UInt64)
    case stale
    case failed
}

private func assertIndexDamagePreservesLastKnownGood(_ damage: IndexDamage) async throws {
    let fixture = try StoreFixture()
    defer { fixture.remove() }
    let lineage = UUID()
    try await fixture.store.claim(uid: 501, lineageID: lineage)
    let first = try fixture.artifact(lineage: lineage, generation: 1)
    _ = try await fixture.store.promote(first)
    switch damage {
    case .missing:
        try fixture.directory.remove("slot-index.json")
    case .corrupt:
        try fixture.directory.writeAtomically(Data("not-an-index".utf8), to: "slot-index.json")
    case .stale:
        try fixture.writeIndex(currentSlot: "policy-b.slot", generation: 0, hash: first.hash)
    }
    let faultedStore = try RootPolicyStore(rootURL: fixture.root) { checkpoint in
        if checkpoint == .beforeSlotWrite(target: "policy-b.slot") {
            throw InjectedPromotionFailure.stop
        }
    }

    await #expect(throws: InjectedPromotionFailure.stop) {
        _ = try await faultedStore.promote(fixture.artifact(lineage: lineage, generation: 2))
    }

    #expect(try fixture.slotGeneration(named: "policy-a.slot") == 1)
    #expect(try fixture.directory.read("policy-b.slot", maximumBytes: 1_024) == nil)
    #expect(try await fixture.store.recoverNewest().tuple.generation == 1)
}

private func promotionOutcome(
    store: RootPolicyStore,
    artifact: PolicyArtifact
) async -> PromotionOutcome {
    do {
        return .promoted(try await store.promote(artifact).tuple.generation)
    } catch RootPolicyStoreError.staleGeneration {
        return .stale
    } catch {
        return .failed
    }
}

private struct StoreFixture {
    let root: URL
    let store: RootPolicyStore
    let directory: SecureDirectory

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try RootPolicyStore(rootURL: root)
        directory = try SecureDirectory(url: root)
    }

    func artifact(
        lineage: UUID,
        generation: UInt64,
        mode: OperationMode = .alert,
        compatibility: PolicyCompatibility = PolicyCompatibility()
    ) throws -> PolicyArtifact {
        try PolicyArtifact.compile(CompiledPolicyPayload(
            lineageID: lineage,
            generation: generation,
            authorizedUID: 501,
            compatibility: compatibility,
            createdAt: Date(timeIntervalSince1970: Double(generation)),
            operationMode: mode,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: []
        ))
    }

    func slotGeneration(named name: String) throws -> UInt64? {
        guard let data = try directory.read(name, maximumBytes: 24 * 1_024 * 1_024) else {
            return nil
        }
        return try JSONDecoder().decode(PolicySlot.self, from: data).validated().1.generation
    }

    func writeIndex(currentSlot: String, generation: UInt64, hash: Data) throws {
        let index = SlotIndex(
            schemaVersion: SlotIndex.schemaVersion,
            currentSlot: currentSlot,
            generation: generation,
            hash: hash
        )
        try directory.writeAtomically(try JSONEncoder().encode(index), to: "slot-index.json")
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
