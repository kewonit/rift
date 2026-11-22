import Foundation
import GRDB
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

private func prompt(unansweredAction: FilterAction?, deadline: Date) -> PromptRequest {
    PromptRequest(
        nonce: UUID(), providerEpoch: UUID(), lineageID: UUID(), generation: 1,
        flowID: UUID(), observedAt: deadline.addingTimeInterval(-30), deadline: deadline,
        owner: .user(uid: 501), appIdentity: nil, processIdentity: nil,
        direction: .outgoing, transportProtocol: .tcp, endpoint: nil,
        winningRuleID: nil, affectingRuleIDs: [], unansweredAction: unansweredAction
    )
}

private func draft(
    lineage: UUID,
    change: UnansweredAlertChange = .unchanged,
    mode: OperationMode = .alert
) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: mode, activeProfileID: nil,
        enabledLocalGroupIDs: [], rules: [], unansweredAlertChange: change
    )
}

@Test func defaultAlertSettingsAskTheFilterForNothingNew() {
    let defaults = UnansweredAlertSettings(blocks: false, storedWaitSeconds: 0)
    #expect(defaults.waitSeconds == 30)
    #expect(defaults.filterPolicy(filterSupportsIt: true) == nil)
    // A wait Settings never offered is read as the default.
    #expect(UnansweredAlertSettings(blocks: false, storedWaitSeconds: 600).waitSeconds == 30)
    #expect(UnansweredAlertSettings(blocks: false, storedWaitSeconds: -5).waitSeconds == 30)
}

@Test func changedAlertSettingsBecomeAFilterPolicyOnlyWhenTheFilterCanEnforceOne() throws {
    let block = UnansweredAlertSettings(blocks: true, storedWaitSeconds: 0)
    #expect(block.filterPolicy(filterSupportsIt: true)
        == (try UnansweredAlertPolicy(action: .deny, waitSeconds: 30)))
    #expect(block.filterPolicy(filterSupportsIt: false) == nil)

    let longer = UnansweredAlertSettings(blocks: false, storedWaitSeconds: 120)
    #expect(longer.filterPolicy(filterSupportsIt: true)
        == (try UnansweredAlertPolicy(action: .allow, waitSeconds: 120)))
    for choice in UnansweredAlertSettings.waitChoices {
        #expect(UnansweredAlertSettings(blocks: true, storedWaitSeconds: choice)
            .filterPolicy(filterSupportsIt: true)?.waitSeconds == UInt16(choice))
    }
    #expect(UnansweredAlertSettings.waitTitle(15) == "15 seconds")
    #expect(UnansweredAlertSettings.waitTitle(60) == "1 minute")
    #expect(UnansweredAlertSettings.waitTitle(120) == "2 minutes")
}

@Test func anAlertFromAFilterThatBlocksNeedsNoHelpFromTheApp() {
    let deadline = Date(timeIntervalSince1970: 1_000)
    let blocked = prompt(unansweredAction: .deny, deadline: deadline)
    for setting in [true, false] {
        let outcome = UnansweredAlertOutcome(prompt: blocked, blocksUnanswered: setting)
        #expect(outcome == .blockedByFilter)
        #expect(outcome.answerDeadline(for: blocked) == deadline)
    }
}

@Test func anOlderFilterStillGetsTheAppsEarlyBlock() {
    let deadline = Date(timeIntervalSince1970: 1_000)
    // An older filter says nothing. A current one that hasn't taken the
    // setting yet says Allow. Either way the app has to answer for it.
    for action in [FilterAction?.none, .allow] {
        let waiting = prompt(unansweredAction: action, deadline: deadline)
        let fallback = UnansweredAlertOutcome(prompt: waiting, blocksUnanswered: true)
        #expect(fallback == .blockedByApp)
        #expect(fallback.blocks)
        #expect(fallback.answerDeadline(for: waiting) == deadline.addingTimeInterval(-1.5))
        let allowed = UnansweredAlertOutcome(prompt: waiting, blocksUnanswered: false)
        #expect(allowed == .allowedByFilter)
        #expect(!allowed.blocks)
        #expect(allowed.answerDeadline(for: waiting) == deadline)
    }
}

@Test func theCountdownSaysWhatWillHappenAndWhen() {
    let deadline = Date(timeIntervalSince1970: 1_000)
    let waiting = prompt(unansweredAction: .deny, deadline: deadline)
    let blocked = UnansweredAlertOutcome.blockedByFilter
    #expect(blocked.countdownLabel(for: waiting, now: deadline.addingTimeInterval(-95)) == "Blocking in 1:35")
    #expect(blocked.countdownLabel(for: waiting, now: deadline.addingTimeInterval(-9.2)) == "Blocking in 10s")
    #expect(blocked.countdownLabel(for: waiting, now: deadline) == "Not answered — connection blocked")
    let allowed = UnansweredAlertOutcome.allowedByFilter
    #expect(allowed.countdownLabel(for: waiting, now: deadline.addingTimeInterval(-5)) == "Allowing in 5s")
    #expect(allowed.countdownLabel(for: waiting, now: deadline) == "Timed out — connection allowed")
    // The app's own Block lands before the filter's deadline.
    #expect(UnansweredAlertOutcome.blockedByApp
        .countdownLabel(for: waiting, now: deadline.addingTimeInterval(-1.5))
        == "Not answered — connection blocked")
}

@Test func theStoredUnansweredPolicyIsCompiledIntoEverySaveUntilItIsChanged() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = PolicyRepository(
        database: try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    )
    let lineage = UUID()
    let now = Date(timeIntervalSince1970: 100)

    let first = try await repository.save(
        draft(lineage: lineage), extensionHighWater: 0, commandKind: "fixture",
        redactedSummary: "fixture", now: now
    )
    #expect(try await repository.unansweredAlerts() == nil)
    #expect(try first.artifact.decode().unansweredAlerts == nil)
    #expect(try first.artifact.decode().compatibility.minimumExtensionProtocol == .baseline)

    let block = try UnansweredAlertPolicy(action: .deny, waitSeconds: 60)
    let second = try await repository.save(
        draft(lineage: lineage, change: .set(block)), extensionHighWater: 1,
        commandKind: "fixture", redactedSummary: "fixture", now: now
    )
    #expect(try await repository.unansweredAlerts() == block)
    #expect(try second.artifact.decode().unansweredAlerts == block)
    #expect(try second.artifact.decode().compatibility.minimumExtensionProtocol == .extendedPolicy)

    // A save that doesn't mention it, such as a rule or mode change, keeps it.
    let reread = try #require(try await repository.currentConfiguration())
    #expect(reread.unansweredAlertChange == .unchanged)
    let third = try await repository.save(
        draft(lineage: lineage, mode: .silentDeny), extensionHighWater: 2,
        commandKind: "fixture", redactedSummary: "fixture", now: now
    )
    #expect(try third.artifact.decode().unansweredAlerts == block)

    let fourth = try await repository.save(
        draft(lineage: lineage, change: .set(nil), mode: .silentDeny), extensionHighWater: 3,
        commandKind: "fixture", redactedSummary: "fixture", now: now
    )
    #expect(try await repository.unansweredAlerts() == nil)
    #expect(try fourth.artifact.decode().unansweredAlerts == nil)
    #expect(try fourth.artifact.decode().compatibility.minimumExtensionProtocol == .baseline)
}

@Test func aFailedSaveLeavesTheStoredUnansweredPolicyAlone() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = PolicyRepository(
        database: try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    )
    let lineage = UUID()
    let block = try UnansweredAlertPolicy(action: .deny, waitSeconds: 30)
    _ = try await repository.save(
        draft(lineage: lineage, change: .set(block)), extensionHighWater: 0,
        commandKind: "fixture", redactedSummary: "fixture", now: Date()
    )
    await #expect(throws: PolicyRepositoryError.generationConflict) {
        _ = try await repository.save(
            draft(lineage: lineage, change: .set(nil)), extensionHighWater: 1,
            expectedGeneration: 99, commandKind: "fixture", redactedSummary: "fixture", now: Date()
        )
    }
    #expect(try await repository.unansweredAlerts() == block)
}

@Test func aDatabaseFromBeforeTheSettingStillOpensAndKeepsTheOldBehaviour() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.sqlite")
    let lineage = UUID()
    do {
        let database = try ConfigurationDatabase.open(at: url)
        _ = try await PolicyRepository(database: database).save(
            draft(lineage: lineage), extensionHighWater: 0, commandKind: "fixture",
            redactedSummary: "fixture", now: Date()
        )
        // Put the file back the way the previous schema left it.
        try await database.write { database in
            try database.execute(sql: "ALTER TABLE policy_preferences DROP COLUMN unanswered_alerts")
            try database.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = 'configuration-v7-unanswered-alerts'"
            )
        }
        try database.close()
    }
    let repository = PolicyRepository(database: try ConfigurationDatabase.open(at: url))
    #expect(try await repository.unansweredAlerts() == nil)
    let saved = try await repository.save(
        draft(lineage: lineage), extensionHighWater: 1, commandKind: "fixture",
        redactedSummary: "fixture", now: Date()
    )
    #expect(try saved.artifact.decode().unansweredAlerts == nil)
}

@Test func anUnreadableStoredPolicyStopsTheSaveInsteadOfAllowing() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try ConfigurationDatabase.open(at: directory.appendingPathComponent("config.sqlite"))
    let repository = PolicyRepository(database: database)
    let lineage = UUID()
    _ = try await repository.save(
        draft(lineage: lineage), extensionHighWater: 0, commandKind: "fixture",
        redactedSummary: "fixture", now: Date()
    )
    try await database.write { database in
        try database.execute(
            sql: "UPDATE policy_preferences SET unanswered_alerts = ?",
            arguments: [Data(#"{"action":"ask","waitSeconds":30}"#.utf8)]
        )
    }
    await #expect(throws: DecodingError.self) {
        _ = try await repository.save(
            draft(lineage: lineage), extensionHighWater: 1, commandKind: "fixture",
            redactedSummary: "fixture", now: Date()
        )
    }
    #expect(try await repository.newestDesiredPolicy()?.tuple.generation == 1)
}

@Test func archivedAlertPreferencesCarryTheWaitWithoutChangingOlderArchives() throws {
    let plain = ArchivedAlertPreferences(
        blocksUnanswered: true, answerWaitSeconds: 30, defaultLifetime: AlertDefaults.lastUsed,
        defaultDestination: AlertDefaults.lastUsed, defaultScope: "Current profile"
    )
    #expect(plain.answerWaitSeconds == nil)
    #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("answerWaitSeconds"))

    let longer = ArchivedAlertPreferences(
        blocksUnanswered: true, answerWaitSeconds: 120, defaultLifetime: AlertDefaults.lastUsed,
        defaultDestination: AlertDefaults.lastUsed, defaultScope: "Current profile"
    )
    let decoded = try JSONDecoder().decode(
        ArchivedAlertPreferences.self, from: try JSONEncoder().encode(longer)
    )
    #expect(decoded.answerWaitSeconds == 120)
    #expect(decoded.normalized == decoded)

    // An archive written before the wait could be chosen.
    let older = Data(#"{"blocksUnanswered":true,"defaultLifetime":"Last used","defaultDestination":"Last used","defaultScope":"Current profile"}"#.utf8)
    #expect(try JSONDecoder().decode(ArchivedAlertPreferences.self, from: older).answerWaitSeconds == nil)

    // A wait Settings never offers doesn't survive a restore.
    var edited = longer
    edited.answerWaitSeconds = 3_600
    #expect(edited.normalized.answerWaitSeconds == nil)
}
