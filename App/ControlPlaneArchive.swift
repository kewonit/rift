import AbyssControl
import AbyssCore
import AbyssIPC
import Foundation

enum ConfigurationRestorePhase: Sendable, Equatable {
    case preparing
    case desiredConfigurationSaved
}

enum ConfigurationRestoreOutcome: Sendable, Equatable {
    case enforced
    case savedPendingEnforcement
}

extension ControlPlaneController {
    func configurationArchiveData() async throws -> Data {
        guard let draft = try await repository?.currentConfiguration() else {
            throw ArchiveControllerError.missingConfiguration
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        return try ConfigurationArchiveCodec.export(draft: draft, appVersion: version, now: Date())
    }

    func previewConfigurationArchive(_ data: Data) async throws -> String {
        let payload = try ConfigurationArchiveCodec.decode(data)
        guard let current = try await repository?.currentConfiguration() else {
            guard configurationRecoveryRequired || configurationRecovery != nil else {
                throw ArchiveControllerError.missingConfiguration
            }
            return "Recovery import: \(payload.rules.count) rules, "
                + "\(payload.profiles.count) profiles, \(payload.localGroups.count) groups, "
                + "and \(payload.blocklists.count) blocklists. The invalid database will be preserved in an owner-only quarantine."
        }
        let currentRules = Dictionary(uniqueKeysWithValues: current.rules.map { ($0.id, $0) })
        let incomingRules = Dictionary(uniqueKeysWithValues: payload.rules.map { ($0.id, $0) })
        let added = incomingRules.keys.filter { currentRules[$0] == nil }.count
        let removed = currentRules.keys.filter { incomingRules[$0] == nil }.count
        let changed = incomingRules.filter { id, rule in
            currentRules[id].map { $0 != rule } ?? false
        }.count
        return "Rules: +\(added), −\(removed), \(changed) changed. "
            + "Profiles: \(current.profiles.count) → \(payload.profiles.count); "
            + "groups: \(current.localGroups.count) → \(payload.localGroups.count); "
            + "blocklists: \(current.blocklists.count) → \(payload.blocklists.count)."
    }

    func restoreConfigurationArchive(_ data: Data) async throws -> ConfigurationRestoreOutcome {
        var phase = ConfigurationRestorePhase.preparing
        do {
            let payload = try ConfigurationArchiveCodec.decode(data)
            let recoveredStoreIsEmpty: Bool
            if let repository, configurationRecovery != nil {
                recoveredStoreIsEmpty = try await repository.currentConfiguration() == nil
            } else {
                recoveredStoreIsEmpty = false
            }
            if repository == nil || recoveredStoreIsEmpty {
                guard configurationRecoveryRequired || configurationRecovery != nil else {
                    throw ArchiveControllerError.missingConfiguration
                }
                return try await recoverConfigurationArchive(payload)
            }
            guard let repository,
                  let current = try await repository.currentConfiguration(),
                  let currentDesired = try await repository.newestDesiredPolicy() else {
                throw ArchiveControllerError.missingConfiguration
            }
            guard pendingRestoreBackupURL == nil,
                  try await repository.pendingRestoreRecovery() == nil else {
                throw PolicyRepositoryError.restoreRecoveryInProgress
            }
            guard let backupURL = try await backups?.runPreRestore(now: Date()) else {
                throw ArchiveControllerError.backupUnavailable
            }
            let handshake = try await client.handshake()
            let activeProfile = payload.profiles.first { $0.id == payload.activeProfileID }
            let effectiveMode = activeProfile?.operationModeOverride ?? payload.baseOperationMode
            let rules = try payload.rules.map { try Self.rebase($0, lineageID: current.lineageID) }
            let draft = PolicyConfigurationDraft(
                lineageID: current.lineageID,
                authorizedUID: current.authorizedUID,
                operationMode: effectiveMode,
                baseOperationMode: payload.baseOperationMode,
                activeProfileID: activeProfile?.id,
                enabledLocalGroupIDs: Set(payload.localGroups.filter(\.isEnabled).map(\.id)),
                rules: rules,
                localGroups: payload.localGroups,
                profiles: payload.profiles,
                blocklists: payload.blocklists,
                disabledBlocklistEntries: Set(payload.disabledBlocklistEntries)
            )
            let desired = try await repository.save(
                draft,
                extensionHighWater: handshake.acceptedGenerationHighWater,
                expectedGeneration: currentDesired.tuple.generation,
                restoreBackupName: backupURL.lastPathComponent,
                commandKind: "restoreArchive",
                redactedSummary: "rules=\(payload.rules.count)",
                now: Date()
            )
            phase = .desiredConfigurationSaved
            pendingRestoreBackupURL = backupURL
            try await reconcileSavedPolicy(desired, lineageID: current.lineageID)
            let outcome = try await configurationRestoreOutcome(target: desired.tuple)
            if outcome == .enforced { pendingRestoreBackupURL = nil }
            return outcome
        } catch {
            guard phase == .desiredConfigurationSaved else { throw error }
            return .savedPendingEnforcement
        }
    }

    func retryPendingConfiguration() async throws -> ConfigurationRestoreOutcome {
        guard let current = try await repository?.currentConfiguration() else {
            throw ArchiveControllerError.missingConfiguration
        }
        try await reconcileNewest(lineageID: current.lineageID)
        let outcome = try await configurationRestoreOutcome()
        if outcome == .enforced {
            finishConfigurationRecovery(try await client.handshake())
            pendingRestoreBackupURL = nil
        }
        return outcome
    }

    var canRollbackLastRestore: Bool { pendingRestoreBackupURL != nil }

    func rollbackLastRestore() async throws -> ConfigurationRestoreOutcome {
        var phase = ConfigurationRestorePhase.preparing
        do {
            guard let backupURL = pendingRestoreBackupURL,
                  let backup = try ConfigurationBackupReader.read(backupURL),
                  let repository,
                  let current = try await repository.currentConfiguration(),
                  let currentDesired = try await repository.newestDesiredPolicy() else {
                throw ArchiveControllerError.backupUnavailable
            }
            let handshake = try await client.handshake()
            let rules = try backup.rules.map { try Self.rebase($0, lineageID: current.lineageID) }
            let activeProfile = backup.profiles.first { $0.id == backup.activeProfileID }
            let restored = PolicyConfigurationDraft(
                lineageID: current.lineageID,
                authorizedUID: current.authorizedUID,
                operationMode: activeProfile?.operationModeOverride ?? backup.baseOperationMode,
                baseOperationMode: backup.baseOperationMode,
                activeProfileID: activeProfile?.id,
                enabledLocalGroupIDs: Set(backup.localGroups.filter(\.isEnabled).map(\.id)),
                rules: rules,
                localGroups: backup.localGroups,
                profiles: backup.profiles,
                blocklists: backup.blocklists,
                disabledBlocklistEntries: backup.disabledBlocklistEntries
            )
            let desired = try await repository.save(
                restored,
                extensionHighWater: handshake.acceptedGenerationHighWater,
                expectedGeneration: currentDesired.tuple.generation,
                commandKind: "rollbackRestore",
                redactedSummary: "rules=\(rules.count)",
                now: Date()
            )
            phase = .desiredConfigurationSaved
            try await reconcileSavedPolicy(desired, lineageID: current.lineageID)
            let outcome = try await configurationRestoreOutcome(target: desired.tuple)
            if outcome == .enforced { pendingRestoreBackupURL = nil }
            return outcome
        } catch {
            guard phase == .desiredConfigurationSaved else { throw error }
            return .savedPendingEnforcement
        }
    }

    func configurationRestoreOutcome(
        target: PolicyTuple? = nil
    ) async throws -> ConfigurationRestoreOutcome {
        guard let desired = try await repository?.newestDesiredPolicy(),
              target.map({ $0 == desired.tuple }) ?? true else {
            throw ArchiveControllerError.missingConfiguration
        }
        return desired.state == .enforced ? .enforced : .savedPendingEnforcement
    }

    static func rebase(_ rule: Rule, lineageID: UUID) throws -> Rule {
        try Rule(
            id: rule.id, lineageID: lineageID, revision: rule.revision,
            action: rule.action, priority: rule.priority, process: rule.process,
            destination: rule.destination, transportProtocol: rule.transportProtocol,
            port: rule.port, direction: rule.direction, owner: rule.owner,
            profileID: rule.profileID, localGroupID: rule.localGroupID,
            expiresAt: rule.expiresAt, isEnabled: rule.isEnabled, flags: rule.flags,
            reviewState: rule.reviewState, source: rule.source, notes: rule.notes,
            createdAt: rule.createdAt, modifiedAt: rule.modifiedAt
        )
    }

    func redactedDiagnosticsSummary() async -> RedactedDiagnostics {
        let handshake = try? await client.handshake()
        let settings = try? await history?.settings()
        let historyCounts = try? await history?.diagnosticCounts()
        let configuration = try? await repository?.currentConfiguration()
        let desired = try? await repository?.newestDesiredPolicy()
        let extensionVersion = Bundle(
            url: Bundle.main.bundleURL.appendingPathComponent(
                "Contents/Library/SystemExtensions/AbyssFilter.systemextension"
            )
        )?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let observedLineages = [
            handshake?.boundLineageID,
            handshake?.persisted?.lineageID,
            handshake?.active?.lineageID,
        ]
            .compactMap { $0 }
        let lineageConsistent = configuration.flatMap { configuration in
            observedLineages.isEmpty ? nil
                : observedLineages.allSatisfy { $0 == configuration.lineageID }
        }
        let configurationStatus: String
        if configurationRecoveryRequired { configurationStatus = "validationFailedPreserved" }
        else if repository == nil { configurationStatus = "unavailable" }
        else if configuration == nil { configurationStatus = "readFailed" }
        else if configurationRecovery != nil { configurationStatus = "recoveredAfterQuarantine" }
        else { configurationStatus = "healthy" }
        let historyStatus: String
        if history == nil { historyStatus = "unavailable" }
        else if settings == nil || historyCounts == nil { historyStatus = "readFailed" }
        else if historyRecovery == nil { historyStatus = "healthy" }
        else { historyStatus = "recoveredAfterQuarantine" }
        let diagnostics = RedactedDiagnostics(
            schemaVersion: 2,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            extensionVersion: extensionVersion ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardware: "arm64",
            providerConnectionStatus: handshake == nil ? "unavailable" : "connected",
            configurationDatabaseStatus: configurationStatus,
            runtimeInstanceID: handshake?.runtimeInstanceID,
            providerEpoch: handshake?.providerEpoch,
            readiness: handshake?.readiness.rawValue ?? "unavailable",
            persistedGeneration: handshake?.persisted?.generation,
            activeGeneration: handshake?.active?.generation,
            acceptedGenerationHighWater: handshake?.acceptedGenerationHighWater,
            desiredGeneration: desired?.tuple.generation,
            desiredState: desired?.state.rawValue,
            lineageConsistent: lineageConsistent,
            persistedMatchesDesired: handshake.flatMap { state in
                desired.map { state.persisted == $0.tuple }
            },
            activeMatchesDesired: handshake.flatMap { state in
                desired.map { state.active == $0.tuple }
            },
            ipcMinimum: handshake?.protocolRange.minimum ?? .current,
            ipcMaximum: handshake?.protocolRange.maximum ?? .current,
            snapshotSchemaMinimum: handshake?.snapshotSchemaRange.lowerBound
                ?? CompiledPolicyPayload.currentSchemaVersion,
            snapshotSchemaMaximum: handshake?.snapshotSchemaRange.upperBound
                ?? CompiledPolicyPayload.currentSchemaVersion,
            historyEnabled: settings?.enabled,
            historyMaximumFlows: settings?.maximumFlows,
            visibleHistoryFlowCount: historyCounts?.visibleFlows,
            historyCoverageGapCount: historyCounts?.coverageGaps,
            historyDatabaseStatus: historyStatus,
            quarantinedHistoryItemCount: historyRecovery?.quarantinedItemCount ?? 0,
            ruleCount: configuration?.rules.count,
            profileCount: configuration?.profiles.count,
            localGroupCount: configuration?.localGroups.count,
            activeBlocklistCount: configuration?.blocklists.filter { $0.status == .active }.count,
            disabledBlocklistCount: configuration?.blocklists.filter { $0.status == .disabled }.count,
            pendingPromptCount: pendingPrompts.count,
            eventDropCount: lostEventCount
        )
        return diagnostics
    }

    func handleCLIRequest(_ request: CLIRelayRequest) async throws -> CLIRelayResponse {
        switch request.command {
        case .rulesExportBegin:
            let data = try await configurationArchiveData()
            let transfer = try await cliTransfers.beginDownload(data: data, now: Date())
            return try CLIRelayResponse(
                summary: "Configuration archive ready",
                payload: try SecureIPCCodec.encode(transfer)
            )
        case .rulesImportBegin:
            let transfer = try SecureIPCCodec.decode(CLITransferDescriptor.self, from: request.payload)
            try await cliTransfers.beginUpload(transfer, now: Date())
            return try CLIRelayResponse(summary: "Import stream accepted")
        case .rulesImportAppend:
            let chunk = try SecureIPCCodec.decode(CLITransferChunk.self, from: request.payload)
            try await cliTransfers.appendUpload(chunk, now: Date())
            return try CLIRelayResponse(summary: "Import chunk accepted")
        case .rulesImportPreviewFinish:
            let finish = try SecureIPCCodec.decode(CLITransferFinish.self, from: request.payload)
            let data = try await cliTransfers.finishUpload(finish.transferID, now: Date())
            let summary = try await previewConfigurationArchive(data)
            return try CLIRelayResponse(summary: summary)
        case .profilesList:
            let definitions = try await policyDefinitions()
            let values = definitions.profiles.map {
                CLIProfileValue(id: $0.id, name: $0.name, isActive: $0.id == definitions.active)
            }
            let json = try CanonicalPolicyJSON.encoder().encode(values)
            let summary = values.isEmpty
                ? "No profiles"
                : values.map { "\($0.isActive ? "*" : "-") \($0.name) \($0.id.uuidString.lowercased())" }
                    .joined(separator: "\n")
            return try CLIRelayResponse(summary: summary, json: json)
        case .profilesActivate:
            let value = request.argument?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let definitions = try await policyDefinitions()
            let profile = definitions.profiles.first {
                $0.id.uuidString.caseInsensitiveCompare(value) == .orderedSame
                    || $0.name.caseInsensitiveCompare(value) == .orderedSame
            }
            guard value == "none" || profile != nil else { throw ArchiveControllerError.unknownProfile }
            let result = try await activateProfile(profile?.id)
            let selection = profile.map { "Profile selection saved: \($0.name)." }
                ?? "Profile selection saved: none."
            return try CLIRelayResponse(summary: selection + " " + result.message)
        case .diagnosticsBegin:
            let data = try await redactedDiagnosticsData()
            let transfer = try await cliTransfers.beginDownload(data: data, now: Date())
            return try CLIRelayResponse(
                summary: "Redacted diagnostics ready",
                payload: try SecureIPCCodec.encode(transfer)
            )
        case .transferRead:
            let read = try SecureIPCCodec.decode(CLITransferRead.self, from: request.payload)
            return try CLIRelayResponse(
                summary: "Transfer chunk",
                payload: try SecureIPCCodec.encode(
                    await cliTransfers.readDownload(read, now: Date())
                )
            )
        case .transferFinish:
            let finish = try SecureIPCCodec.decode(CLITransferFinish.self, from: request.payload)
            await cliTransfers.cancel(finish.transferID)
            return try CLIRelayResponse(summary: "Transfer released")
        }
    }
}

final class AppRelayHandler: NSObject, AbyssAppRelayXPC, @unchecked Sendable {
    private let operation: @Sendable (CLIRelayRequest) async throws -> CLIRelayResponse
    private let runtimeSignal: @Sendable () async -> Void

    init(
        operation: @escaping @Sendable (CLIRelayRequest) async throws -> CLIRelayResponse,
        runtimeSignal: @escaping @Sendable () async -> Void
    ) {
        self.operation = operation
        self.runtimeSignal = runtimeSignal
    }

    func performCLIRequest(
        _ request: SecureIPCEnvelope,
        withReply reply: @escaping (SecureIPCReply) -> Void
    ) {
        let operation = self.operation
        let reply = AppRelayReply(reply)
        Task {
            do {
                guard request.messageKind == .cliRequest,
                      request.protocolVersion.isCompatible(with: .current) else {
                    throw ArchiveControllerError.invalidRelayRequest
                }
                let value = try SecureIPCCodec.decode(CLIRelayRequest.self, from: request.payload)
                let response = try await operation(value)
                reply.call(SecureIPCReply(
                    requestID: request.requestID,
                    status: .success,
                    payload: try SecureIPCCodec.encode(response)
                ))
            } catch {
                reply.call(SecureIPCReply(
                    requestID: request.requestID,
                    status: .rejected,
                    redactedErrorCode: String(describing: type(of: error))
                ))
            }
        }
    }

    func runtimeDataAvailable(withReply reply: @escaping () -> Void) {
        let signal = runtimeSignal
        let reply = AppRelayVoidReply(reply)
        Task {
            await signal()
            reply.call()
        }
    }
}

private final class AppRelayReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((SecureIPCReply) -> Void)?

    init(_ handler: @escaping (SecureIPCReply) -> Void) {
        self.handler = handler
    }

    func call(_ reply: SecureIPCReply) {
        let pending = lock.withLock {
            defer { handler = nil }
            return handler
        }
        pending?(reply)
    }
}

private final class AppRelayVoidReply: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        let pending = lock.withLock {
            defer { handler = nil }
            return handler
        }
        pending?()
    }
}

private struct CLIProfileValue: Codable {
    let id: UUID
    let name: String
    let isActive: Bool
}

struct RedactedDiagnostics: Codable {
    let schemaVersion: UInt16
    let appVersion: String
    let extensionVersion: String
    let osVersion: String
    let hardware: String
    let providerConnectionStatus: String
    let configurationDatabaseStatus: String
    let runtimeInstanceID: UUID?
    let providerEpoch: UUID?
    let readiness: String
    let persistedGeneration: UInt64?
    let activeGeneration: UInt64?
    let acceptedGenerationHighWater: UInt64?
    let desiredGeneration: UInt64?
    let desiredState: String?
    let lineageConsistent: Bool?
    let persistedMatchesDesired: Bool?
    let activeMatchesDesired: Bool?
    let ipcMinimum: ProtocolVersion
    let ipcMaximum: ProtocolVersion
    let snapshotSchemaMinimum: UInt16
    let snapshotSchemaMaximum: UInt16
    let historyEnabled: Bool?
    let historyMaximumFlows: Int?
    let visibleHistoryFlowCount: Int?
    let historyCoverageGapCount: Int?
    let historyDatabaseStatus: String
    let quarantinedHistoryItemCount: Int
    let ruleCount: Int?
    let profileCount: Int?
    let localGroupCount: Int?
    let activeBlocklistCount: Int?
    let disabledBlocklistCount: Int?
    let pendingPromptCount: Int
    let eventDropCount: UInt64
}
