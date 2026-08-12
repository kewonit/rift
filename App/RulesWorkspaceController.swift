import RiftControl
import RiftCore
import Foundation
import Observation

@MainActor
@Observable
final class RulesWorkspaceController {
    enum RequestedFocusResult: Equatable {
        case focused
        case notFound
        case loadFailed
    }

    private(set) var rows: [RuleRowViewValue] = []
    private(set) var hierarchy: [RuleWorkspaceNode] = []
    private(set) var groups: [LocalRuleGroup] = []
    private(set) var profiles: [PolicyProfile] = []
    private(set) var blocklists: [BlocklistSource] = []
    private(set) var activeProfileID: UUID?
    private(set) var enforcementState: PolicyOutboxState = .savedPendingEnforcement
    private(set) var previewEnvironment: RulePreviewEnvironment?
    private(set) var identityChoices: [RuleIdentityChoice] = [
        RuleIdentityChoice(process: .anyProcess, permitsSystemOwner: false)
    ]
    private(set) var generation: UInt64 = 0
    var sidebarSelection: RulesSidebarSelection = .filter(.all)
    var search = ""
    var searchScope: RuleSearchScope = .all
    var actionFilter: RuleActionFilter = .all
    var sort: RuleWorkspaceSort = .automatic
    var selection: Set<UUID> = []
    private(set) var errorMessage: String?
    let controlPlane: ControlPlaneController
    var allRules: [Rule] = []
    private var reloadTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var historyPlan: RuleWorkspaceUndoPlan?
    private var historyOperationName = ""
    private var historyIsRedo = false
    private(set) var historyCommandTitle: String?
    private(set) var historyCommandIsRunning = false

    var historyCommandIsRedo: Bool { historyCommandTitle != nil && historyIsRedo }

    init(controlPlane: ControlPlaneController) {
        self.controlPlane = controlPlane
    }

    var selectedRow: RuleRowViewValue? {
        guard let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    var sidebarTitle: String {
        let value: String
        switch sidebarSelection {
        case .filter(let filter):
            value = filter.rawValue
        case .profile(let id):
            value = profiles.first { $0.id == id }?.name ?? "Profile"
        case .group(let id):
            value = groups.first { $0.id == id }?.name ?? "Group"
        case .blocklist(let id):
            value = blocklists.first { $0.id == id }?.name ?? "Blocklist"
        }
        return DisplaySanitizer.plainText(value)
    }

    var eligibleSelectionCount: Int {
        rows.filter {
            selection.contains($0.id)
                && !$0.rule.flags.contains(.protected)
                && !$0.rule.flags.contains(.sourceManaged)
        }.count
    }
    var skippedSelectionCount: Int { selection.count - eligibleSelectionCount }
    var selectedRowIsEditable: Bool {
        guard selection.count == 1, let selectedRow else { return false }
        return !selectedRow.rule.flags.contains(.protected)
            && !selectedRow.rule.flags.contains(.sourceManaged)
    }

    func deferTableSelection(_ value: Set<UUID>) {
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            let availableIDs = Set(rows.map(\.id))
            selection = value.intersection(availableIDs)
        }
    }

    func selectRulesImmediately(_ value: Set<UUID>) {
        selectionTask?.cancel()
        selection = value.intersection(Set(rows.map(\.id)))
    }

    func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func focusRuleIDs(_ ids: Set<UUID>) -> RequestedFocusResult {
        let available = ids.intersection(Set(rows.map(\.id)))
        selection = available
        if available.isEmpty, !ids.isEmpty {
            errorMessage = "The corresponding rule was removed or is not available to this policy owner."
            return .notFound
        }
        return .focused
    }

    func focusRuleIDsAfterReload(_ ids: Set<UUID>) async -> RequestedFocusResult {
        reloadTask?.cancel()
        sidebarSelection = .filter(.all)
        search = ""
        searchScope = .all
        actionFilter = .all
        sort = .automatic
        guard await reload() else { return .loadFailed }
        return focusRuleIDs(ids)
    }

    @discardableResult
    func reload() async -> Bool {
        do {
            guard let workspace = try await controlPlane.ruleWorkspaceSnapshot() else {
                throw ControlPlaneController.RuleCommandError.missingConfiguration
            }
            normalizeSidebarSelection(for: workspace.configuration)
            let values = workspace.rows(
                filter: sidebarSelection.listFilter,
                search: search,
                searchScope: searchScope,
                actionFilter: actionFilter,
                collection: sidebarSelection.collectionFilter,
                sort: sort
            )
            let identities = try await controlPlane.ruleIdentityChoices()
            let preview = try await controlPlane.rulePreviewEnvironment(
                configuration: workspace.configuration
            )
            let availableIDs = Set(values.map(\.id))
            let preservedSelection = selection.intersection(availableIDs)
            if preservedSelection != selection {
                selection = preservedSelection
            }
            hierarchy = RuleWorkspaceHierarchy.nodes(rows: values)
            rows = values
            allRules = workspace.configuration.rules
            groups = workspace.configuration.localGroups
            profiles = workspace.configuration.profiles
            blocklists = workspace.configuration.blocklists
            activeProfileID = workspace.configuration.activeProfileID
            enforcementState = workspace.enforcementState
            identityChoices = identities
            previewEnvironment = preview
            generation = workspace.generation
            if !historyCommandIsRunning,
               let historyPlan,
               historyPlan.expectedGeneration != workspace.generation {
                clearHistoryCommand()
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Rules could not be loaded. Retry after the control plane reconnects."
            return false
        }
    }

    func setSelectedEnabled(_ enabled: Bool) async {
        await ruleCommand(enabled ? "Enable Rules" : "Disable Rules") {
            try await controlPlane.setRulesEnabled(selection, enabled: enabled, expectedGeneration: generation)
        }
    }

    func markSelectedReviewed(_ reviewed: Bool) async {
        await ruleCommand(reviewed ? "Mark Rules Reviewed" : "Mark Rules Unreviewed") {
            try await controlPlane.markRulesReviewed(selection, reviewed: reviewed, expectedGeneration: generation)
        }
    }

    func deleteSelected() async {
        await ruleCommand("Delete Rules") {
            try await controlPlane.deleteRules(selection, expectedGeneration: generation)
        }
    }

    func duplicateSelected() async {
        guard let id = selection.first else { return }
        await ruleCommand("Duplicate Rule") {
            try await controlPlane.duplicateRule(id, expectedGeneration: generation)
        }
    }

    func assignSelectedToGroup(_ groupID: UUID?) async {
        await ruleCommand("Move Rules to Group") {
            try await controlPlane.assignRulesToGroup(
                selection, groupID: groupID, expectedGeneration: generation
            )
        }
    }

    func assignSelectedToProfile(_ profileID: UUID?) async {
        await ruleCommand("Move Rules to Profile") {
            try await controlPlane.assignRulesToProfile(
                selection, profileID: profileID, expectedGeneration: generation
            )
        }
    }

    func prepareRuleDrop(
        ruleIDs: Set<UUID>,
        target: RuleWorkspaceDropTarget,
        operation: RuleWorkspaceDropOperation
    ) -> RuleWorkspaceDropRequest? {
        do {
            let plan = try RuleWorkspaceDropPlan(
                rules: allRules,
                selectedRuleIDs: ruleIDs,
                target: target,
                operation: operation
            )
            let request = RuleWorkspaceDropRequest(
                ruleIDs: ruleIDs,
                target: target,
                targetName: collectionName(for: target),
                operation: operation,
                affectedCount: plan.affectedRuleIDs.count,
                skippedCount: plan.skippedRuleIDs.count,
                unchangedCount: plan.unchangedRuleIDs.count,
                newRuleIDs: operation == .copy
                    ? plan.affectedRuleIDs.map { _ in UUID() }
                    : []
            )
            selectRulesImmediately(ruleIDs)
            errorMessage = nil
            return request
        } catch RuleWorkspaceDropError.noEligibleRules {
            errorMessage = "Protected and blocklist-managed rules cannot be reorganized."
        } catch RuleWorkspaceDropError.noChanges {
            errorMessage = "The selected rules are already assigned to that collection."
        } catch {
            errorMessage = "The selected rules changed. Reload and try the drop again."
        }
        return nil
    }

    func performRuleDrop(_ request: RuleWorkspaceDropRequest) async {
        let collection = request.target.isGroup ? "Group" : "Profile"
        let action = request.operation == .copy ? "Copy" : "Move"
        let succeeded = await ruleCommand("\(action) Rules to \(collection)") {
            try await controlPlane.applyRuleWorkspaceDrop(
                request.ruleIDs,
                target: request.target,
                operation: request.operation,
                newRuleIDs: request.newRuleIDs,
                expectedGeneration: generation
            )
        }
        if succeeded {
            selection = request.resultRuleIDs.intersection(Set(rows.map(\.id)))
        }
    }

    private func collectionName(for target: RuleWorkspaceDropTarget) -> String {
        switch target {
        case .localGroup(let id): groups.first { $0.id == id }?.name ?? "Group"
        case .profile(let id): profiles.first { $0.id == id }?.name ?? "Profile"
        }
    }

    func edit(_ id: UUID, draft: ManualRuleDraft) async -> Bool {
        await ruleCommand("Edit Rule") {
            try await controlPlane.editRule(
                id, draft: draft, expectedGeneration: generation
            )
        }
    }

    func create(_ draft: ManualRuleDraft) async -> Bool {
        await ruleCommand("Create Rule") {
            try await controlPlane.createManualRule(
                draft, expectedGeneration: generation
            )
        }
    }

    func performHistoryCommand() async {
        guard !historyCommandIsRunning, let plan = historyPlan else { return }
        guard generation == plan.expectedGeneration else {
            clearHistoryCommand()
            reportNotSaved("Undo is no longer available because the configuration changed.")
            return
        }
        let previousRules = allRules
        let actionName = historyOperationName
        let wasRedo = historyIsRedo
        historyCommandIsRunning = true
        defer { historyCommandIsRunning = false }
        let result: ConfigurationMutationResult
        do {
            result = try await controlPlane.applyRuleWorkspaceUndo(plan)
        } catch {
            await reload()
            clearHistoryCommand()
            reportNotSaved(
                "\(wasRedo ? "Redo" : "Undo") was not saved because the configuration changed."
            )
            return
        }
        guard await reload() else {
            clearHistoryCommand()
            reportNotSaved(
                "\(wasRedo ? "Redo" : "Undo") was saved, but the current rules could not reload."
            )
            return
        }
        let (expectedGeneration, overflow) = plan.expectedGeneration.addingReportingOverflow(1)
        guard !overflow, generation == expectedGeneration else {
            clearHistoryCommand()
            reportNotSaved(
                "\(wasRedo ? "Redo" : "Undo") completed, but a newer configuration is already active."
            )
            present(result)
            return
        }
        do {
            historyPlan = try RuleWorkspaceUndoPlan(
                beforeMutation: previousRules,
                afterMutation: allRules,
                expectedGeneration: generation
            )
        } catch {
            clearHistoryCommand()
            reportNotSaved(
                "\(wasRedo ? "Redo" : "Undo") was saved, but the reverse command is unavailable."
            )
            present(result)
            return
        }
        historyOperationName = actionName
        historyIsRedo = !wasRedo
        historyCommandTitle = "\(historyIsRedo ? "Redo" : "Undo") \(actionName)"
        selection = plan.affectedRuleIDs.intersection(Set(rows.map(\.id)))
        present(result)
    }

    @discardableResult
    private func ruleCommand(
        _ actionName: String,
        _ operation: () async throws -> ConfigurationMutationResult
    ) async -> Bool {
        let beforeMutation = allRules
        let previousGeneration = generation
        do {
            let result = try await operation()
            let loaded = await reload()
            if loaded {
                registerHistoryCommand(
                    actionName: actionName,
                    beforeMutation: beforeMutation,
                    previousGeneration: previousGeneration
                )
            } else {
                clearHistoryCommand()
            }
            present(result)
            return true
        } catch {
            await reload()
            reportNotSaved(
                "The command was not saved. The configuration changed; review and retry."
            )
            return false
        }
    }

    private func registerHistoryCommand(
        actionName: String,
        beforeMutation: [Rule],
        previousGeneration: UInt64
    ) {
        let (expectedGeneration, overflow) = previousGeneration.addingReportingOverflow(1)
        guard !overflow, generation == expectedGeneration else {
            clearHistoryCommand()
            reportNotSaved("Saved, but Undo is unavailable because the configuration changed again.")
            return
        }
        do {
            historyPlan = try RuleWorkspaceUndoPlan(
                beforeMutation: beforeMutation,
                afterMutation: allRules,
                expectedGeneration: generation
            )
            historyOperationName = actionName
            historyIsRedo = false
            historyCommandTitle = "Undo \(actionName)"
        } catch RuleWorkspaceUndoError.noChanges {
            clearHistoryCommand()
        } catch {
            clearHistoryCommand()
            reportNotSaved("Saved, but this change cannot be undone safely.")
        }
    }

    private func clearHistoryCommand() {
        historyPlan = nil
        historyOperationName = ""
        historyIsRedo = false
        historyCommandTitle = nil
    }

    func definitionCommand(
        _ failureMessage: String,
        operation: () async throws -> ConfigurationMutationResult
    ) async -> Bool {
        do {
            let result = try await operation()
            await reload()
            present(result)
            return true
        } catch {
            await reload()
            reportNotSaved(failureMessage)
            return false
        }
    }

    private func normalizeSidebarSelection(for configuration: PolicyConfigurationDraft) {
        let exists: Bool
        switch sidebarSelection {
        case .filter:
            exists = true
        case .profile(let id):
            exists = configuration.profiles.contains { $0.id == id }
        case .group(let id):
            exists = configuration.localGroups.contains { $0.id == id }
        case .blocklist(let id):
            exists = configuration.blocklists.contains { $0.id == id }
        }
        if !exists { sidebarSelection = .filter(.all) }
    }

    private func present(_ result: ConfigurationMutationResult) {
        guard result.requiresAttention else { return }
        errorMessage = [result.message, errorMessage].compactMap { $0 }.joined(separator: " ")
    }

    private func reportNotSaved(_ message: String) {
        errorMessage = [message, errorMessage].compactMap { $0 }.joined(separator: " ")
    }
}
