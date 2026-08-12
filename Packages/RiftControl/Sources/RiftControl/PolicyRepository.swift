import RiftCore
import RiftIPC
import Foundation
import GRDB

private enum RootHighWaterSource {
    case live(UInt64)
    case authenticatedOffline(AuthenticatedRootHighWater)
}
public actor PolicyRepository {
    private let database: DatabasePool

    public init(database: DatabasePool) {
        self.database = database
    }

    public func save(
        _ draft: PolicyConfigurationDraft,
        extensionHighWater: UInt64,
        expectedGeneration: UInt64? = nil,
        restoreBackupName: String? = nil,
        commandKind: String,
        redactedSummary: String,
        now: Date
    ) throws -> DesiredPolicy {
        try saveValidated(
            draft,
            rootHighWater: .live(extensionHighWater),
            expectedGeneration: expectedGeneration,
            restoreBackupName: restoreBackupName,
            commandKind: commandKind,
            redactedSummary: redactedSummary,
            now: now
        )
    }

    public func saveOffline(
        _ draft: PolicyConfigurationDraft,
        authenticatedRoot: AuthenticatedRootHighWater,
        expectedGeneration: UInt64,
        commandKind: String,
        redactedSummary: String,
        now: Date
    ) throws -> DesiredPolicy {
        try saveValidated(
            draft,
            rootHighWater: .authenticatedOffline(authenticatedRoot),
            expectedGeneration: expectedGeneration,
            restoreBackupName: nil,
            commandKind: commandKind,
            redactedSummary: redactedSummary,
            now: now
        )
    }

    private func saveValidated(
        _ draft: PolicyConfigurationDraft,
        rootHighWater: RootHighWaterSource,
        expectedGeneration: UInt64?,
        restoreBackupName: String?,
        commandKind: String,
        redactedSummary: String,
        now: Date
    ) throws -> DesiredPolicy {
        try database.write { database in
            try PolicyConfigurationValidator.validate(draft)
            if let restoreBackupName {
                guard Self.validRestoreBackupName(restoreBackupName) else {
                    throw PolicyRepositoryError.invalidRestoreBackupName
                }
                let recoveryInProgress = try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS (SELECT 1 FROM restore_recovery WHERE singleton_id = 1)"
                ) ?? true
                guard !recoveryInProgress else {
                    throw PolicyRepositoryError.restoreRecoveryInProgress
                }
            }
            let metadata = try Row.fetchOne(database, sql: "SELECT * FROM policy_metadata WHERE singleton_id = 1")
            let localGeneration = try Self.validateOwner(metadata, draft: draft)
            if let expectedGeneration, expectedGeneration != localGeneration {
                throw PolicyRepositoryError.generationConflict
            }
            let extensionHighWater: UInt64
            switch rootHighWater {
            case .live(let value):
                extensionHighWater = value
            case .authenticatedOffline(let anchor):
                let recoveryInProgress = try Bool.fetchOne(
                    database,
                    sql: "SELECT EXISTS (SELECT 1 FROM restore_recovery WHERE singleton_id = 1)"
                ) ?? true
                guard let row = try Row.fetchOne(
                    database,
                    sql: "SELECT * FROM policy_outbox ORDER BY generation DESC LIMIT 1"
                ) else {
                    throw PolicyRepositoryError.missingGeneration
                }
                let localDesired = try Self.desiredPolicy(from: row).tuple
                guard localDesired.generation == localGeneration else {
                    throw PolicyRepositoryError.acknowledgementMismatch
                }
                extensionHighWater = try OfflineMutationSafety.validateOfflineSave(
                    anchor: anchor,
                    localDesired: localDesired,
                    recoveryInProgress: recoveryInProgress
                )
            }
            let highWater = max(localGeneration, extensionHighWater)
            guard highWater < UInt64(Int64.max) else { throw PolicyRepositoryError.generationOverflow }
            let generation = highWater + 1
            let payload = try CompiledPolicyPayload(
                lineageID: draft.lineageID,
                generation: generation,
                authorizedUID: draft.authorizedUID,
                createdAt: now,
                operationMode: draft.operationMode,
                activeProfileID: draft.activeProfileID,
                enabledLocalGroupIDs: draft.enabledLocalGroupIDs,
                rules: try BlocklistPolicyCompiler.effectiveRules(for: draft)
            )
            let artifact = try PolicyArtifact.compile(payload)
            try Self.replaceConfiguration(database, draft: draft, generation: generation, now: now)
            try database.execute(
                sql: """
                    INSERT INTO policy_outbox
                        (generation, lineage_id, created_at, content_hash, artifact, state)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    Int64(generation), draft.lineageID.uuidString.lowercased(), now.timeIntervalSince1970,
                    artifact.hash, artifact.bytes, PolicyOutboxState.savedPendingEnforcement.rawValue,
                ]
            )
            try database.execute(
                sql: """
                    INSERT INTO command_audit (generation, command_kind, created_at, redacted_summary)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    Int64(generation), String(commandKind.prefix(64)), now.timeIntervalSince1970,
                    String(redactedSummary.prefix(256)),
                ]
            )
            if let restoreBackupName {
                try database.execute(
                    sql: """
                        INSERT INTO restore_recovery
                            (singleton_id, backup_name, target_generation, created_at)
                        VALUES (1, ?, ?, ?)
                        """,
                    arguments: [
                        restoreBackupName, Int64(generation), now.timeIntervalSince1970,
                    ]
                )
            }
            try Self.pruneAuditState(database)
            return DesiredPolicy(
                tuple: PolicyTuple(lineageID: draft.lineageID, generation: generation, hash: artifact.hash),
                artifact: artifact,
                createdAt: now,
                state: .savedPendingEnforcement,
                providerEpoch: nil
            )
        }
    }

    public func pendingRestoreRecovery() throws -> PendingRestoreRecovery? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT backup_name, target_generation, created_at FROM restore_recovery WHERE singleton_id = 1"
            ) else { return nil }
            let backupName: String = row["backup_name"]
            let generation: Int64 = row["target_generation"]
            let createdAt: Double = row["created_at"]
            guard Self.validRestoreBackupName(backupName), generation >= 0 else {
                throw PolicyRepositoryError.invalidRestoreBackupName
            }
            return PendingRestoreRecovery(
                backupName: backupName,
                targetGeneration: UInt64(generation),
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        }
    }

    public func clearPendingRestoreRecovery(throughGeneration generation: UInt64) throws {
        guard generation <= UInt64(Int64.max) else { return }
        try database.write { database in
            try database.execute(
                sql: "DELETE FROM restore_recovery WHERE target_generation <= ?",
                arguments: [Int64(generation)]
            )
        }
    }

    public func newestDesiredPolicy() throws -> DesiredPolicy? {
        try database.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT * FROM policy_outbox ORDER BY generation DESC LIMIT 1"
            ) else { return nil }
            return try Self.desiredPolicy(from: row)
        }
    }

    public func currentConfiguration() throws -> PolicyConfigurationDraft? {
        try database.read { database in
            try PolicyConfigurationReader.read(database)
        }
    }

    public func markPersisted(_ tuple: PolicyTuple, at now: Date) throws {
        try mutateAcknowledgement(tuple, providerEpoch: nil, state: .persistedPendingProvider, now: now)
    }

    public func markEnforced(_ tuple: PolicyTuple, providerEpoch: UUID, at now: Date) throws {
        try mutateAcknowledgement(tuple, providerEpoch: providerEpoch, state: .enforced, now: now)
    }

    public func markApplyFailed(_ tuple: PolicyTuple, at now: Date) throws {
        try mutateAcknowledgement(tuple, providerEpoch: nil, state: .applyFailed, now: now)
    }

    public func recordUsage(_ batch: RuntimeEventBatch) throws {
        try database.write { database in
            let row = try Row.fetchOne(
                database,
                sql: "SELECT state, provider_epoch FROM usage_coverage WHERE singleton_id = 1"
            )
            let priorState = (row?["state"] as String?).flatMap(HistoryCoverage.init(rawValue:))
                ?? .gap
            let priorEpoch: String? = row?["provider_epoch"]
            let nextEpoch = batch.providerEpoch?.uuidString.lowercased()
            let epochChanged = priorEpoch != nil && nextEpoch != nil && priorEpoch != nextEpoch
            let coverage: HistoryCoverage
            if priorState == .gap {
                coverage = .gap
            } else if epochChanged || batch.droppedCount > 0 {
                coverage = .partial
            } else {
                coverage = priorState
            }
            try database.execute(
                sql: "UPDATE usage_coverage SET state = ?, provider_epoch = COALESCE(?, provider_epoch) WHERE singleton_id = 1",
                arguments: [coverage.rawValue, nextEpoch]
            )
            for event in batch.events where event.kind == .decision {
                var affected = Set(event.affectingRuleIDs)
                if let winner = event.winningRuleID { affected.insert(winner) }
                for id in affected {
                    let value = id.uuidString.lowercased()
                    try database.execute(
                        sql: """
                            INSERT INTO rule_usage (rule_id, lower_bound_count, last_used_at)
                            SELECT ?, 1, ? WHERE EXISTS (SELECT 1 FROM rules WHERE id = ?)
                            ON CONFLICT(rule_id) DO UPDATE SET
                                lower_bound_count = CASE
                                    WHEN rule_usage.lower_bound_count < 9223372036854775807
                                    THEN rule_usage.lower_bound_count + 1
                                    ELSE rule_usage.lower_bound_count
                                END,
                                last_used_at = MAX(rule_usage.last_used_at, excluded.last_used_at)
                            """,
                        arguments: [value, event.occurredAt.timeIntervalSince1970, value]
                    )
                }
            }
        }
    }

    public func markUsagePartial() throws {
        try database.write {
            try $0.execute(
                sql: "UPDATE usage_coverage SET state = 'partial' WHERE singleton_id = 1 AND state = 'complete'"
            )
        }
    }

    public func markUsageGap() throws {
        try database.write { database in
            try database.execute(
                sql: "UPDATE usage_coverage SET state = ? WHERE singleton_id = 1",
                arguments: [HistoryCoverage.gap.rawValue]
            )
        }
    }

    public func clearUsage() throws {
        try database.write { database in
            try database.execute(sql: "DELETE FROM rule_usage")
            try database.execute(
                sql: "UPDATE usage_coverage SET state = ?, provider_epoch = NULL WHERE singleton_id = 1",
                arguments: [HistoryCoverage.gap.rawValue]
            )
        }
    }

    public func ruleUsage(ruleIDs: Set<UUID>) throws -> [UUID: RuleUsageValue] {
        guard !ruleIDs.isEmpty else { return [:] }
        return try database.read { database in
            let stateValue = try String.fetchOne(
                database,
                sql: "SELECT state FROM usage_coverage WHERE singleton_id = 1"
            )
            let coverage = stateValue.flatMap(HistoryCoverage.init(rawValue:)) ?? .gap
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT rule_id, lower_bound_count, last_used_at FROM rule_usage"
            )
            var stored: [UUID: (Int, Date?)] = [:]
            for row in rows {
                let value: String = row["rule_id"]
                guard let id = UUID(uuidString: value), ruleIDs.contains(id) else { continue }
                let count: Int64 = row["lower_bound_count"]
                let date: Double? = row["last_used_at"]
                stored[id] = (Int(clamping: count), date.map(Date.init(timeIntervalSince1970:)))
            }
            return Dictionary(uniqueKeysWithValues: ruleIDs.map { id in
                let value = stored[id] ?? (0, nil)
                return (id, RuleUsageValue(
                    lowerBoundCount: value.0, lastUsedAt: value.1, coverage: coverage
                ))
            })
        }
    }

    private func mutateAcknowledgement(
        _ tuple: PolicyTuple,
        providerEpoch: UUID?,
        state: PolicyOutboxState,
        now: Date
    ) throws {
        try database.write { database in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT lineage_id, content_hash FROM policy_outbox WHERE generation = ?",
                arguments: [Int64(tuple.generation)]
            ) else { throw PolicyRepositoryError.missingGeneration }
            let lineage: String = row["lineage_id"]
            let hash: Data = row["content_hash"]
            guard lineage == tuple.lineageID.uuidString.lowercased(), hash == tuple.hash else {
                throw PolicyRepositoryError.acknowledgementMismatch
            }
            if state == .enforced {
                try database.execute(
                    sql: """
                        UPDATE policy_outbox
                        SET state = ?, provider_epoch = ?, persisted_at = COALESCE(persisted_at, ?), enforced_at = ?
                        WHERE generation <= ? AND lineage_id = ?
                        """,
                    arguments: [
                        state.rawValue, providerEpoch?.uuidString.lowercased(), now.timeIntervalSince1970,
                        now.timeIntervalSince1970, Int64(tuple.generation), lineage,
                    ]
                )
            } else if state == .persistedPendingProvider {
                try database.execute(
                    sql: "UPDATE policy_outbox SET state = ?, persisted_at = ? WHERE generation = ?",
                    arguments: [state.rawValue, now.timeIntervalSince1970, Int64(tuple.generation)]
                )
            } else {
                try database.execute(
                    sql: "UPDATE policy_outbox SET state = ? WHERE generation = ?",
                    arguments: [state.rawValue, Int64(tuple.generation)]
                )
            }
        }
    }

    private static func validateOwner(_ row: Row?, draft: PolicyConfigurationDraft) throws -> UInt64 {
        guard let row else { return 0 }
        let owner: Int64 = row["authorized_uid"]
        let lineage: String = row["lineage_id"]
        guard owner == Int64(draft.authorizedUID) else { throw PolicyRepositoryError.ownerMismatch }
        guard lineage == draft.lineageID.uuidString.lowercased() else {
            throw PolicyRepositoryError.lineageMismatch
        }
        let generation: Int64 = row["desired_generation"]
        guard generation >= 0 else { throw PolicyRepositoryError.acknowledgementMismatch }
        return UInt64(generation)
    }

    private static func pruneAuditState(_ database: Database) throws {
        try database.execute(sql: """
            DELETE FROM policy_outbox WHERE generation NOT IN (
                SELECT generation FROM policy_outbox ORDER BY generation DESC LIMIT 3
            )
            """)
        try database.execute(sql: """
            DELETE FROM command_audit WHERE sequence NOT IN (
                SELECT sequence FROM command_audit ORDER BY sequence DESC LIMIT 1000
            )
            """)
    }

    private static func validRestoreBackupName(_ value: String) -> Bool {
        value.count <= 160
            && value == (value as NSString).lastPathComponent
            && value.hasPrefix("pre-restore-")
            && value.hasSuffix(".sqlite")
            && !value.contains("\0")
    }

    private static func replaceConfiguration(
        _ database: Database,
        draft: PolicyConfigurationDraft,
        generation: UInt64,
        now: Date
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO policy_metadata
                    (singleton_id, lineage_id, authorized_uid, desired_generation, operation_mode,
                     active_profile_id, modified_at)
                VALUES (1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(singleton_id) DO UPDATE SET
                    desired_generation = excluded.desired_generation,
                    operation_mode = excluded.operation_mode,
                    active_profile_id = excluded.active_profile_id,
                    modified_at = excluded.modified_at
                """,
            arguments: [
                draft.lineageID.uuidString.lowercased(), Int64(draft.authorizedUID), Int64(generation),
                draft.operationMode.rawValue, draft.activeProfileID?.uuidString.lowercased(),
                now.timeIntervalSince1970,
            ]
        )
        try database.execute(sql: "DELETE FROM rules")
        let encoder = CanonicalPolicyJSON.encoder()
        for rule in draft.rules {
            try database.execute(
                sql: "INSERT INTO rules (id, encoded_rule, modified_at) VALUES (?, ?, ?)",
                arguments: [
                    rule.id.uuidString.lowercased(), try encoder.encode(rule), now.timeIntervalSince1970,
                ]
            )
        }
        try database.execute(
            sql: "DELETE FROM rule_usage WHERE rule_id NOT IN (SELECT id FROM rules)"
        )
        try database.execute(sql: "DELETE FROM enabled_local_groups")
        for groupID in draft.enabledLocalGroupIDs {
            try database.execute(
                sql: "INSERT INTO enabled_local_groups (id) VALUES (?)",
                arguments: [groupID.uuidString.lowercased()]
            )
        }
        try database.execute(sql: "DELETE FROM local_group_definitions")
        for group in draft.localGroups {
            try database.execute(
                sql: "INSERT INTO local_group_definitions (id, encoded_value) VALUES (?, ?)",
                arguments: [group.id.uuidString.lowercased(), try encoder.encode(group)]
            )
        }
        try database.execute(sql: "DELETE FROM profile_definitions")
        for profile in draft.profiles {
            try database.execute(
                sql: "INSERT INTO profile_definitions (id, encoded_value) VALUES (?, ?)",
                arguments: [profile.id.uuidString.lowercased(), try encoder.encode(profile)]
            )
        }
        try database.execute(sql: "DELETE FROM blocklist_sources")
        for source in draft.blocklists {
            try database.execute(
                sql: "INSERT INTO blocklist_sources (id, encoded_value) VALUES (?, ?)",
                arguments: [source.id.uuidString.lowercased(), try encoder.encode(source)]
            )
        }
        try BlocklistOverrideStore.replace(database, entries: draft.disabledBlocklistEntries)
        try database.execute(
            sql: "UPDATE policy_preferences SET base_mode = ? WHERE singleton_id = 1",
            arguments: [draft.baseOperationMode.rawValue]
        )
    }

    private static func desiredPolicy(from row: Row) throws -> DesiredPolicy {
        let lineageString: String = row["lineage_id"]
        let generation: Int64 = row["generation"]
        let hash: Data = row["content_hash"]
        let bytes: Data = row["artifact"]
        let createdAt: Double = row["created_at"]
        let stateString: String = row["state"]
        let epochString: String? = row["provider_epoch"]
        guard let lineage = UUID(uuidString: lineageString),
              generation >= 0,
              let state = PolicyOutboxState(rawValue: stateString) else {
            throw PolicyRepositoryError.acknowledgementMismatch
        }
        return DesiredPolicy(
            tuple: PolicyTuple(lineageID: lineage, generation: UInt64(generation), hash: hash),
            artifact: try PolicyArtifact(bytes: bytes, hash: hash),
            createdAt: Date(timeIntervalSince1970: createdAt),
            state: state,
            providerEpoch: epochString.flatMap(UUID.init(uuidString:))
        )
    }
}
