import AbyssCore
import AbyssIPC
import Foundation

public struct RuleWorkspaceSnapshot: Sendable {
    public let configuration: PolicyConfigurationDraft
    public let enforcementState: PolicyOutboxState
    public let desiredTuple: PolicyTuple
    public let generation: UInt64
    public let usage: [UUID: RuleUsageValue]

    public init(
        configuration: PolicyConfigurationDraft,
        enforcementState: PolicyOutboxState,
        desiredTuple: PolicyTuple,
        generation: UInt64,
        usage: [UUID: RuleUsageValue]
    ) {
        self.configuration = configuration
        self.enforcementState = enforcementState
        self.desiredTuple = desiredTuple
        self.generation = generation
        self.usage = usage
    }

    public func presentingEnforcementState(_ state: PolicyOutboxState) -> RuleWorkspaceSnapshot {
        RuleWorkspaceSnapshot(
            configuration: configuration,
            enforcementState: state,
            desiredTuple: desiredTuple,
            generation: generation,
            usage: usage
        )
    }

    public func rows(
        filter: RuleListFilter,
        search: String,
        searchScope: RuleSearchScope = .all,
        actionFilter: RuleActionFilter = .all,
        collection: RuleCollectionFilter = .all,
        sort: RuleWorkspaceSort = .automatic,
        now: Date = Date()
    ) -> [RuleRowViewValue] {
        RuleWorkspaceQuery.rows(
            rules: configuration.rules,
            state: enforcementState,
            generation: generation,
            filter: filter,
            search: search,
            searchScope: searchScope,
            actionFilter: actionFilter,
            collection: collection,
            sort: sort,
            context: RuleWorkspaceQueryContext(configuration: configuration, now: now),
            usage: usage
        )
    }
}

public extension PolicyRepository {
    func ruleWorkspaceSnapshot() throws -> RuleWorkspaceSnapshot? {
        guard let configuration = try currentConfiguration(),
              let desired = try newestDesiredPolicy() else { return nil }
        let payload = try desired.artifact.decode()
        guard payload.lineageID == configuration.lineageID,
              payload.generation == desired.tuple.generation,
              payload.authorizedUID == configuration.authorizedUID,
              payload.operationMode == configuration.operationMode,
              payload.activeProfileID == configuration.activeProfileID,
              Set(payload.enabledLocalGroupIDs) == configuration.enabledLocalGroupIDs,
              payload.rules == configuration.rules.sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
            throw PolicyRepositoryError.acknowledgementMismatch
        }
        let usage = try ruleUsage(ruleIDs: Set(configuration.rules.map(\.id)))
        return RuleWorkspaceSnapshot(
            configuration: configuration,
            enforcementState: desired.state,
            desiredTuple: desired.tuple,
            generation: desired.tuple.generation,
            usage: usage
        )
    }
}
