import AbyssCore
import AbyssIPC
import Foundation
import Testing
@testable import AbyssFilterRuntime

@Test func referencedExpiryKeysIncludeActiveAndPreviousSlots() async throws {
    let fixture = try ExpiryReconciliationFixture()
    defer { fixture.remove() }
    let firstRule = try fixture.temporaryRule(expiresAt: Date(timeIntervalSince1970: 100))
    let secondRule = try fixture.temporaryRule(expiresAt: Date(timeIntervalSince1970: 200))
    let firstKey = try #require(firstRule.expiryKey)
    let secondKey = try #require(secondRule.expiryKey)

    _ = try await fixture.promote(generation: 1, rules: [firstRule])
    _ = try await fixture.promote(generation: 2, rules: [secondRule])
    #expect(try await fixture.policyStore.recoverNewest().tuple.generation == 2)

    #expect(try await fixture.policyStore.referencedExpiryKeys() == [firstKey, secondKey])
}

@Test func tombstoneRemainsUntilNeitherFixedSlotReferencesIt() async throws {
    let fixture = try ExpiryReconciliationFixture()
    defer { fixture.remove() }
    let rule = try fixture.temporaryRule(expiresAt: Date(timeIntervalSince1970: 100))
    let key = try #require(rule.expiryKey)
    let unrelated = ExpiredRuleKey(
        lineageID: fixture.lineageID,
        ruleID: UUID(),
        revision: 9,
        expiresAt: Date(timeIntervalSince1970: 90)
    )
    _ = try await fixture.tombstones.record([key, unrelated])

    _ = try await fixture.promote(generation: 1, rules: [rule])
    #expect(await fixture.reconcile() == .available(alreadyExpired: [key]))

    _ = try await fixture.promote(generation: 2, rules: [])
    #expect(await fixture.reconcile() == .available(alreadyExpired: [key]))

    _ = try await fixture.promote(generation: 3, rules: [])
    #expect(await fixture.reconcile() == .available(alreadyExpired: []))
    #expect(try await fixture.tombstones.load().isEmpty)
}

@Test func corruptPreviousSlotPreventsPruning() async throws {
    let fixture = try ExpiryReconciliationFixture()
    defer { fixture.remove() }
    let rule = try fixture.temporaryRule(expiresAt: Date(timeIntervalSince1970: 100))
    let key = try #require(rule.expiryKey)
    let unrelated = ExpiredRuleKey(
        lineageID: fixture.lineageID,
        ruleID: UUID(),
        revision: 2,
        expiresAt: Date(timeIntervalSince1970: 80)
    )
    let original = Set([key, unrelated])
    _ = try await fixture.tombstones.record(original)
    _ = try await fixture.promote(generation: 1, rules: [rule])
    _ = try await fixture.promote(generation: 2, rules: [])
    try fixture.directory.writeAtomically(Data("corrupt previous slot".utf8), to: "policy-a.slot")

    #expect(try await fixture.policyStore.recoverNewest().tuple.generation == 2)
    #expect(await fixture.reconcile() == .unavailable)
    #expect(try await fixture.tombstones.load() == original)
}

@Test func operationalSlotFailurePreventsPruning() async throws {
    let fixture = try ExpiryReconciliationFixture()
    defer { fixture.remove() }
    let rule = try fixture.temporaryRule(expiresAt: Date(timeIntervalSince1970: 100))
    let key = try #require(rule.expiryKey)
    _ = try await fixture.tombstones.record([key])
    _ = try await fixture.promote(generation: 1, rules: [rule])
    try fixture.directory.remove("policy-b.slot")
    try FileManager.default.createDirectory(
        at: fixture.root.appendingPathComponent("policy-b.slot"),
        withIntermediateDirectories: false
    )

    await #expect(throws: SecureDirectoryError.notRegularFile) {
        _ = try await fixture.policyStore.recoverNewest()
    }
    #expect(await fixture.reconcile() == .unavailable)
    #expect(try await fixture.tombstones.load() == [key])
}

@Test func pruneWriteFailureKeepsRuntimeDegradedAndTemporaryRuleFailSafe() async throws {
    let fixture = try ExpiryReconciliationFixture()
    defer { fixture.remove() }
    let rule = try fixture.temporaryRule(expiresAt: Date(timeIntervalSince1970: 100))
    let key = try #require(rule.expiryKey)
    _ = try await fixture.tombstones.record([key])
    let recovered = try await fixture.promote(
        generation: 1,
        mode: .silentAllow,
        rules: [rule]
    )
    let faultedTombstones = try ExpiryTombstoneStore(rootURL: fixture.root) { checkpoint in
        if checkpoint == .beforeWrite { throw InjectedExpiryWriteFailure.stop }
    }

    let metadata = await ExpiryTombstoneReconciler.reconcileAfterSuccessfulPolicyLoad(
        policyStore: fixture.policyStore,
        tombstoneStore: faultedTombstones
    )
    #expect(metadata == .unavailable)
    #expect(try await fixture.tombstones.load() == [key])

    var persistence = ProviderPersistenceState()
    persistence.beginProviderStart(
        rootPersistenceAvailable: true,
        tombstonePersistenceAvailable: true
    )
    persistence.rootPersistenceSucceeded()
    _ = persistence.tombstonePersistenceFailed()
    #expect(persistence.completeProviderStart(
        settingsSucceeded: true,
        hasActivePolicy: true
    ) == .degradedPersistence)

    let runtime = RuntimePolicy(recovered: recovered, expiryMetadata: metadata)
    #expect(!runtime.expiryMetadataAvailable)
    let decision = runtime.decision(
        for: try expiryTestFlow(),
        now: Date(timeIntervalSince1970: 50)
    )
    #expect(decision.filter.action == .allow)
    #expect(decision.issues.contains { $0.reason == .expiryMetadataUnavailable })
}

private enum InjectedExpiryWriteFailure: Error {
    case stop
}

private struct ExpiryReconciliationFixture {
    let root: URL
    let policyStore: RootPolicyStore
    let tombstones: ExpiryTombstoneStore
    let directory: SecureDirectory
    let lineageID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        policyStore = try RootPolicyStore(rootURL: root)
        tombstones = try ExpiryTombstoneStore(rootURL: root)
        directory = try SecureDirectory(url: root)
    }

    func promote(
        generation: UInt64,
        mode: OperationMode = .alert,
        rules: [Rule]
    ) async throws -> RecoveredPolicy {
        if generation == 1 {
            try await policyStore.claim(uid: 501, lineageID: lineageID)
        }
        return try await policyStore.promote(try PolicyArtifact.compile(CompiledPolicyPayload(
            lineageID: lineageID,
            generation: generation,
            authorizedUID: 501,
            createdAt: Date(timeIntervalSince1970: Double(generation)),
            operationMode: mode,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: rules
        )))
    }

    func temporaryRule(expiresAt: Date) throws -> Rule {
        try Rule(
            id: UUID(),
            lineageID: lineageID,
            revision: 1,
            action: .filter(.deny),
            priority: .normal,
            process: .anyProcess,
            destination: .anyEndpoint,
            transportProtocol: .anySupportedProtocol,
            port: nil,
            direction: .bidirectional,
            owner: .authorizedUser,
            expiresAt: expiresAt,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1)
        )
    }

    func reconcile() async -> ExpiryMetadata {
        await ExpiryTombstoneReconciler.reconcileAfterSuccessfulPolicyLoad(
            policyStore: policyStore,
            tombstoneStore: tombstones
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func expiryTestFlow() throws -> FlowDescriptor {
    let remote = Endpoint(
        address: try IPAddress("203.0.113.7"),
        port: 443,
        hostname: nil,
        hostnameCoverage: .absent,
        classes: [],
        interfaceSnapshotGeneration: 1
    )
    return FlowDescriptor(
        flowID: UUID(),
        observedAt: Date(timeIntervalSince1970: 50),
        sourceAppIdentity: nil,
        sourceProcessIdentity: nil,
        owner: .user(uid: 501),
        direction: .outgoing,
        transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: remote,
        observedHostname: nil,
        metadataConfidence: [.endpoint, .owner]
    )
}
