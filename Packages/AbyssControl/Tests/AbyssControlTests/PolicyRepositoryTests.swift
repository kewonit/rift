import AbyssCore
import AbyssIPC
import Foundation
import Testing
@testable import AbyssControl

@Test func policySaveIsAtomicAndAdvancesAboveExtensionHighWater() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    let repository = PolicyRepository(database: database)
    let lineage = UUID()
    let draft = PolicyConfigurationDraft(
        lineageID: lineage,
        authorizedUID: 501,
        operationMode: .alert,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: []
    )

    let saved = try await repository.save(
        draft, extensionHighWater: 41, commandKind: "fixture",
        redactedSummary: "empty fixture", now: Date(timeIntervalSince1970: 100)
    )
    #expect(saved.tuple.generation == 42)
    #expect(try saved.artifact.decode().createdAt == Date(timeIntervalSince1970: 100))
    #expect(try await repository.newestDesiredPolicy() == saved)
}

@Test func acknowledgementRequiresExactTuple() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = PolicyRepository(
        database: try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    )
    let draft = PolicyConfigurationDraft(
        lineageID: UUID(), authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: []
    )
    let saved = try await repository.save(
        draft, extensionHighWater: 0, commandKind: "fixture",
        redactedSummary: "fixture", now: Date(timeIntervalSince1970: 100)
    )
    let wrong = PolicyTuple(
        lineageID: saved.tuple.lineageID,
        generation: saved.tuple.generation,
        hash: Data(repeating: 0, count: 32)
    )
    await #expect(throws: PolicyRepositoryError.acknowledgementMismatch) {
        try await repository.markPersisted(wrong, at: Date())
    }

    try await repository.markApplyFailed(saved.tuple, at: Date(timeIntervalSince1970: 101))
    #expect(try await repository.newestDesiredPolicy()?.state == .applyFailed)
    try await repository.markPersisted(saved.tuple, at: Date(timeIntervalSince1970: 102))
    #expect(try await repository.newestDesiredPolicy()?.state == .persistedPendingProvider)
    let epoch = UUID()
    try await repository.markEnforced(
        saved.tuple, providerEpoch: epoch, at: Date(timeIntervalSince1970: 103)
    )
    let enforced = try await repository.newestDesiredPolicy()
    #expect(enforced?.state == .enforced)
    #expect(enforced?.providerEpoch == epoch)
}

@Test func configurationDatabaseRejectsCorruptionWithoutReplacingIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("config.sqlite")
    let corrupt = Data("not a sqlite database".utf8)
    try corrupt.write(to: url)

    #expect(throws: (any Error).self) { try ConfigurationDatabase.open(at: url) }
    #expect(try Data(contentsOf: url) == corrupt)
}

@Test func ruleUsagePersistsSeparatelyFromHistoryAndCanClearIndependently() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = PolicyRepository(
        database: try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    )
    let lineage = UUID()
    let winner = UUID()
    let affecting = UUID()
    let unused = UUID()
    let now = Date(timeIntervalSince1970: 2_000)
    let rules = try [winner, affecting, unused].map {
        try Rule(
            id: $0, lineageID: lineage, revision: 1, action: .filter(.allow),
            priority: .normal, process: .anyProcess, destination: .anyEndpoint,
            transportProtocol: .anySupportedProtocol, port: nil, direction: .outgoing,
            owner: .authorizedUser, createdAt: now, modifiedAt: now
        )
    }
    _ = try await repository.save(
        PolicyConfigurationDraft(
            lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow,
            activeProfileID: nil, enabledLocalGroupIDs: [], rules: rules
        ),
        extensionHighWater: 0, commandKind: "usageFixture",
        redactedSummary: "three rules", now: now
    )
    let epoch = UUID()
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: now, sourceAppIdentity: nil, sourceProcessIdentity: nil,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp,
        localEndpoint: nil, remoteEndpoint: nil, observedHostname: nil, metadataConfidence: []
    )
    let event = RuntimeEvent(
        providerEpoch: epoch, sequence: 1, occurredAt: now, flow: flow,
        action: .allow, reason: .concreteDecision, policy: nil,
        winningRuleID: winner, affectingRuleIDs: [winner, affecting]
    )
    try await repository.recordUsage(
        RuntimeEventBatch(providerEpoch: epoch, events: [event], droppedCount: 1)
    )
    let usage = try await repository.ruleUsage(ruleIDs: [winner, affecting, unused])
    #expect(usage[winner]?.lowerBoundCount == 1)
    #expect(usage[affecting]?.lastUsedAt == now)
    #expect(usage[unused]?.lowerBoundCount == 0)
    #expect(usage[unused]?.coverage == .partial)

    try await repository.clearUsage()
    let cleared = try await repository.ruleUsage(ruleIDs: [winner])
    #expect(cleared[winner]?.lowerBoundCount == 0)
    #expect(cleared[winner]?.coverage == .gap)
}
