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
    /// Rules couldn't load at all, so there's nothing to show.
    private(set) var errorMessage: String?
    /// Something worth saying that doesn't stop rules from being shown.
    private(set) var notice: String?
    let controlPlane: ControlPlaneController
    var allRules: [Rule] = []
    private var reloadTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?

    var historyCommandTitle: String? {
        controlPlane.canUndoRuleChange ? controlPlane.ruleChanges.title : nil
    }
    var historyCommandIsRunning: Bool { controlPlane.ruleChanges.isRunning }
    var historyCommandIsRedo: Bool { controlPlane.ruleChanges.isRedo }

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
            notice = "That rule no longer exists or isn’t available to your account."
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
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Couldn’t load rules. Try again once Rift reconnects to the filter."
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
            notice = nil
            return request
        } catch RuleWorkspaceDropError.noEligibleRules {
            notice = "Protected and blocklist rules can’t be moved."
        } catch RuleWorkspaceDropError.noChanges {
            notice = "These rules are already there."
        } catch {
            notice = "The selected rules changed. Try dragging them again."
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
        let history = controlPlane.ruleChanges
        guard !history.isRunning, history.plan != nil else { return }
        guard controlPlane.canUndoRuleChange else {
            history.clear()
            reportNotSaved("Undo isn’t available because your rules changed.")
            return
        }
        let wasRedo = history.isRedo
        let affected = history.plan?.affectedRuleIDs ?? []
        do {
            let result = try await controlPlane.undoLastRuleChange()
            guard await reload() else {
                reportNotSaved(
                    "\(wasRedo ? "Redo" : "Undo") worked, but Rift couldn’t reload your rules."
                )
                return
            }
            selection = affected.intersection(Set(rows.map(\.id)))
            if let result { present(result) }
        } catch {
            await reload()
            history.clear()
            reportNotSaved(
                "Couldn’t \(wasRedo ? "redo" : "undo") because your rules changed."
            )
        }
    }

    @discardableResult
    private func ruleCommand(
        _ actionName: String,
        _ operation: () async throws -> ConfigurationMutationResult
    ) async -> Bool {
        controlPlane.ruleChanges.nextChangeName = actionName
        defer { controlPlane.ruleChanges.nextChangeName = nil }
        do {
            let result = try await operation()
            await reload()
            present(result)
            return true
        } catch {
            await reload()
            reportNotSaved(
                "The change wasn’t saved. Your rules may have changed, so check them and try again."
            )
            return false
        }
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
        notice = [result.message, notice].compactMap { $0 }.joined(separator: " ")
    }

    func dismissNotice() { notice = nil }

    private func reportNotSaved(_ message: String) {
        notice = [message, notice].compactMap { $0 }.joined(separator: " ")
    }
}
