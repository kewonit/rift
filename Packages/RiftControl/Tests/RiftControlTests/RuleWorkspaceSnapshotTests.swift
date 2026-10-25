import RiftControl
import RiftCore
import Foundation
import Testing

@Test func workspaceSnapshotSupportsFirstRuleAndFilteredEmptyMutations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = PolicyRepository(
        database: try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    )
    let lineage = UUID()
    let initial = PolicyConfigurationDraft(
        lineageID: lineage,
        authorizedUID: 501,
        operationMode: .silentAllow,
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        rules: []
    )
    let firstPolicy = try await repository.save(
        initial,
        extensionHighWater: 0,
        expectedGeneration: 0,
        commandKind: "initial",
        redactedSummary: "empty",
        now: Date(timeIntervalSince1970: 100)
    )

    let loadedEmptySnapshot = try await repository.ruleWorkspaceSnapshot()
    let emptySnapshot = try #require(loadedEmptySnapshot)
    #expect(emptySnapshot.generation == firstPolicy.tuple.generation)
    #expect(emptySnapshot.rows(filter: .all, search: "").isEmpty)

    let now = Date(timeIntervalSince1970: 101)
    let firstRule = try Rule(
        id: UUID(), lineageID: emptySnapshot.configuration.lineageID, revision: 1,
        action: .filter(.allow), priority: .normal, process: .anyProcess,
        destination: .normalizedExactHostnameSet([try DomainName("api.example.test")]),
        transportProtocol: .tcp, port: try PortRange(443, 443), direction: .outgoing,
        owner: .authorizedUser, createdAt: now, modifiedAt: now
    )
    let withFirstRule = configuration(emptySnapshot.configuration, rules: [firstRule])
    let secondPolicy = try await repository.save(
        withFirstRule,
        extensionHighWater: 0,
        expectedGeneration: emptySnapshot.generation,
        commandKind: "createRule",
        redactedSummary: "one",
        now: now
    )

    let loadedFilteredSnapshot = try await repository.ruleWorkspaceSnapshot()
    let filteredSnapshot = try #require(loadedFilteredSnapshot)
    #expect(filteredSnapshot.generation == secondPolicy.tuple.generation)
    #expect(filteredSnapshot.rows(filter: .all, search: "does-not-match").isEmpty)

    let disabled = try RuleMutation.enabled(
        firstRule,
        value: false,
        now: Date(timeIntervalSince1970: 102)
    )
    let thirdPolicy = try await repository.save(
        configuration(filteredSnapshot.configuration, rules: [disabled]),
        extensionHighWater: 0,
        expectedGeneration: filteredSnapshot.generation,
        commandKind: "setEnabled",
        redactedSummary: "one",
        now: Date(timeIntervalSince1970: 102)
    )
    #expect(thirdPolicy.tuple.generation == filteredSnapshot.generation + 1)
    #expect(try await repository.currentConfiguration()?.rules.first?.isEnabled == false)
}

private func configuration(
    _ source: PolicyConfigurationDraft,
    rules: [Rule]
) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: source.lineageID,
        authorizedUID: source.authorizedUID,
        operationMode: source.operationMode,
        baseOperationMode: source.baseOperationMode,
        activeProfileID: source.activeProfileID,
        enabledLocalGroupIDs: source.enabledLocalGroupIDs,
        rules: rules,
        localGroups: source.localGroups,
        profiles: source.profiles,
        blocklists: source.blocklists
    )
}
