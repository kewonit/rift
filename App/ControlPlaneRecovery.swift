import AbyssControl
import AbyssIPC
import Darwin
import Foundation

extension ControlPlaneController {
    func prepareConfigurationRecoveryConnection() async {
        await installConnectionHooks()
        requestReconnect()
    }

    func prepareForUninstall() async -> Bool {
        do {
            if configurationRecoveryRequired {
                let recoveryClient = client
                try await ConfigurationRecoveryUninstall.prepare(
                    undisclosedLineageID: UUID(),
                    connect: { try await recoveryClient.connect() },
                    handshake: { try await recoveryClient.handshake() },
                    requireCurrentConnection: {
                        try await recoveryClient.requireCurrentConnection($0)
                    },
                    claimController: { lineageID, connectionID in
                        _ = try await recoveryClient.claimController(
                            lineageID: lineageID,
                            requiring: connectionID
                        )
                    },
                    prepareUninstall: { try await recoveryClient.prepareUninstall() }
                )
            } else {
                try await client.prepareUninstall()
            }
            return true
        } catch {
            recordStartupIssue("Root policy cleanup could not be verified, so Abyss did not request extension deactivation. Retry while the policy-owner account is the current console user.")
            return false
        }
    }

    func resetConfiguration() async throws -> ConfigurationRestoreOutcome {
        guard configurationRecoveryRequired,
              repository == nil,
              let configurationDatabaseURL,
              let supportDirectoryURL else {
            throw ArchiveControllerError.recoveryUnavailable
        }
        let recoveryClient = client
        let connectionID = try await recoveryClient.connect()
        let handshake = try await recoveryClient.handshake()
        try await recoveryClient.requireCurrentConnection(connectionID)
        let plan = try ConfigurationResetRecovery.plan(
            from: handshake,
            proposedLineageID: UUID()
        )
        _ = try await recoveryClient.claimController(
            lineageID: plan.claimLineageID,
            requiring: connectionID
        )
        let recovered = try await ConfigurationDatabase.recoverByQuarantining(
            at: configurationDatabaseURL,
            now: Date(),
            beforePromotion: {
                try Task.checkCancellation()
                try await recoveryClient.requireCurrentConnection(connectionID)
                try await recoveryClient.beginConfigurationReset(
                    targetLineageID: plan.targetLineageID
                )
                try await recoveryClient.requireCurrentConnection(connectionID)
            }
        ) { database in
            let repository = PolicyRepository(database: database)
            let empty = PolicyConfigurationDraft(
                lineageID: plan.targetLineageID,
                authorizedUID: getuid(),
                operationMode: .silentAllow,
                activeProfileID: nil,
                enabledLocalGroupIDs: [],
                rules: []
            )
            return try await repository.save(
                empty,
                extensionHighWater: 0,
                expectedGeneration: 0,
                commandKind: "resetConfiguration",
                redactedSummary: "silentAllow rules=0",
                now: Date()
            )
        }
        let desired = recovered.value
        do {
            try await installRecoveredConfiguration(
                recovered.result,
                support: supportDirectoryURL
            )
        } catch {
            configurationRecoveryRequired = false
            markConfigurationRecoveryPending()
        }
        guard repository != nil else { throw ArchiveControllerError.recoveryUnavailable }
        currentMode = .silentAllow
        do {
            try await reconcileSavedPolicy(
                desired,
                lineageID: plan.targetLineageID
            )
        } catch {
            markConfigurationRecoveryPending()
            return .savedPendingEnforcement
        }
        let outcome = (try? await configurationRestoreOutcome(target: desired.tuple))
            ?? .savedPendingEnforcement
        if outcome == .enforced {
            do {
                finishConfigurationRecovery(try await recoveryClient.handshake())
            } catch {
                markConfigurationRecoveryPending()
            }
        } else {
            markConfigurationRecoveryPending()
        }
        return outcome
    }

    func recoverConfigurationArchive(
        _ payload: ConfigurationArchivePayload
    ) async throws -> ConfigurationRestoreOutcome {
        try await client.connect()
        let handshake = try await client.handshake()
        let observedLineages = Set([
            handshake.boundLineageID,
            handshake.persisted?.lineageID,
            handshake.active?.lineageID,
        ].compactMap { $0 })
        guard observedLineages.count <= 1 else {
            throw ArchiveControllerError.rootLineageUnavailable
        }
        let lineageID: UUID
        if let existing = observedLineages.first {
            lineageID = existing
        } else {
            guard handshake.acceptedGenerationHighWater == 0,
                  handshake.persisted == nil,
                  handshake.active == nil else {
                throw ArchiveControllerError.rootLineageUnavailable
            }
            lineageID = UUID()
        }

        let activeProfile = payload.profiles.first { $0.id == payload.activeProfileID }
        let rules = try payload.rules.map { try Self.rebase($0, lineageID: lineageID) }
        let recovered = PolicyConfigurationDraft(
            lineageID: lineageID,
            authorizedUID: getuid(),
            operationMode: activeProfile?.operationModeOverride ?? payload.baseOperationMode,
            baseOperationMode: payload.baseOperationMode,
            activeProfileID: activeProfile?.id,
            enabledLocalGroupIDs: Set(payload.localGroups.filter(\.isEnabled).map(\.id)),
            rules: rules,
            localGroups: payload.localGroups,
            profiles: payload.profiles,
            blocklists: payload.blocklists,
            disabledBlocklistEntries: Set(payload.disabledBlocklistEntries)
        )
        let desired: DesiredPolicy
        if repository == nil {
            guard let configurationDatabaseURL, let supportDirectoryURL else {
                throw ArchiveControllerError.recoveryUnavailable
            }
            let recovery = try await ConfigurationDatabase.recoverByQuarantining(
                at: configurationDatabaseURL,
                now: Date()
            ) { database in
                let stagedRepository = PolicyRepository(database: database)
                return try await stagedRepository.save(
                    recovered,
                    extensionHighWater: handshake.acceptedGenerationHighWater,
                    expectedGeneration: 0,
                    commandKind: "recoverConfigurationArchive",
                    redactedSummary: "rules=\(rules.count)",
                    now: Date()
                )
            }
            desired = recovery.value
            do {
                try await installRecoveredConfiguration(
                    recovery.result,
                    support: supportDirectoryURL
                )
            } catch {
                configurationRecoveryRequired = false
                markConfigurationRecoveryPending()
            }
            guard repository != nil else { throw ArchiveControllerError.recoveryUnavailable }
        } else {
            guard let repository,
                  try await repository.currentConfiguration() == nil,
                  try await repository.newestDesiredPolicy() == nil else {
                throw ArchiveControllerError.recoveryUnavailable
            }
            desired = try await repository.save(
                recovered,
                extensionHighWater: handshake.acceptedGenerationHighWater,
                expectedGeneration: 0,
                commandKind: "recoverConfigurationArchive",
                redactedSummary: "rules=\(rules.count)",
                now: Date()
            )
        }
        currentMode = recovered.operationMode
        do {
            try await reconcileSavedPolicy(desired, lineageID: lineageID)
        } catch {
            markConfigurationRecoveryPending()
            return (try? await configurationRestoreOutcome(target: desired.tuple))
                ?? .savedPendingEnforcement
        }
        let outcome = (try? await configurationRestoreOutcome(target: desired.tuple))
            ?? .savedPendingEnforcement
        guard outcome == .enforced else {
            markConfigurationRecoveryPending()
            return outcome
        }
        do {
            finishConfigurationRecovery(try await client.handshake())
        } catch {
            markConfigurationRecoveryPending()
        }
        return outcome
    }
}

enum ArchiveControllerError: Error {
    case missingConfiguration
    case backupUnavailable
    case invalidRelayRequest
    case unknownProfile
    case recoveryUnavailable
    case rootLineageUnavailable
}
