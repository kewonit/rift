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
    private(set) var hasLoaded = false
    /// Edit Rules… is open for the selected rules.
    var bulkEditing = false
    /// A file chosen in Import Rules, waiting for the person to confirm.
    private(set) var pendingImport: PendingRuleImport?
    let controlPlane: ControlPlaneController
    var allRules: [Rule] = []
    private var reloadTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?

    var historyCommandIsRunning: Bool { controlPlane.ruleChanges.isRunning }

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
            value = filter.title
        case .profile(let id):
            value = profiles.first { $0.id == id }?.name ?? String(localized: "Profile")
        case .group(let id):
            value = groups.first { $0.id == id }?.name ?? String(localized: "Group")
        case .blocklist(let id):
            value = blocklists.first { $0.id == id }?.name ?? String(localized: "Blocklist")
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
            notice = String(localized: "That rule no longer exists or isn’t available to your account.")
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
            hasLoaded = true
            return true
        } catch {
            errorMessage = String(localized: "Couldn’t load rules. Try again once Rift reconnects to the filter.")
            return false
        }
    }

    func setSelectedEnabled(_ enabled: Bool) async {
        await ruleCommand(enabled ? String(localized: "Enable Rules") : String(localized: "Disable Rules")) {
            try await controlPlane.setRulesEnabled(selection, enabled: enabled, expectedGeneration: generation)
        }
    }

    func markSelectedReviewed(_ reviewed: Bool) async {
        await ruleCommand(reviewed ? String(localized: "Mark Rules Reviewed") : String(localized: "Mark Rules Unreviewed")) {
            try await controlPlane.markRulesReviewed(selection, reviewed: reviewed, expectedGeneration: generation)
        }
    }

    func makeSelectedPermanent() async {
        await ruleCommand(String(localized: "Make Rules Permanent")) {
            try await controlPlane.makeRulesPermanent(selection, expectedGeneration: generation)
        }
    }

    /// The selected rules that Edit Rules… changes.
    var bulkEditableRules: [Rule] {
        allRules.filter {
            selection.contains($0.id)
                && !$0.flags.contains(.protected) && !$0.flags.contains(.sourceManaged)
        }
    }

    func editSelected(_ edit: RuleBulkEdit) async -> Bool {
        let ids = selection
        return await ruleCommand(String(localized: "Edit Rules")) {
            try await controlPlane.mutateRules(expectedGeneration: generation, kind: "editRules") { rules in
                try edit.applied(to: rules, ids: ids, now: Date())
            }
        }
    }

    func deleteSelected() async {
        await ruleCommand(String(localized: "Delete Rules")) {
            try await controlPlane.deleteRules(selection, expectedGeneration: generation)
        }
    }

    /// The rules a maintenance list shows that can be deleted: not
    /// protected, and not kept up to date by a blocklist or subscription.
    var deletableShownRuleIDs: Set<UUID> {
        Set(rows.map(\.rule).filter {
            !$0.flags.contains(.protected) && !$0.flags.contains(.sourceManaged)
        }.map(\.id))
    }

    /// Deletes every rule the current maintenance list shows.
    func deleteAllShown() async {
        let ids = deletableShownRuleIDs
        guard !ids.isEmpty else { return }
        await ruleCommand(String(localized: "Delete Rules")) {
            try await controlPlane.deleteRules(ids, expectedGeneration: generation)
        }
    }

    func duplicateSelected() async {
        guard let id = selection.first else { return }
        await ruleCommand(String(localized: "Duplicate Rule")) {
            try await controlPlane.duplicateRule(id, expectedGeneration: generation)
        }
    }

    func assignSelectedToGroup(_ groupID: UUID?) async {
        await ruleCommand(String(localized: "Move Rules to Group")) {
            try await controlPlane.assignRulesToGroup(
                selection, groupID: groupID, expectedGeneration: generation
            )
        }
    }

    func assignSelectedToProfile(_ profileID: UUID?) async {
        await ruleCommand(String(localized: "Move Rules to Profile")) {
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
            notice = String(localized: "Protected and blocklist rules can’t be moved.")
        } catch RuleWorkspaceDropError.noChanges {
            notice = String(localized: "These rules are already there.")
        } catch {
            notice = String(localized: "The selected rules changed. Try dragging them again.")
        }
        return nil
    }

    func performRuleDrop(_ request: RuleWorkspaceDropRequest) async {
        let actionName = switch (request.operation == .copy, request.target.isGroup) {
        case (true, true): String(localized: "Copy Rules to Group")
        case (true, false): String(localized: "Copy Rules to Profile")
        case (false, true): String(localized: "Move Rules to Group")
        case (false, false): String(localized: "Move Rules to Profile")
        }
        let succeeded = await ruleCommand(actionName) {
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
        case .localGroup(let id): groups.first { $0.id == id }?.name ?? String(localized: "Group")
        case .profile(let id): profiles.first { $0.id == id }?.name ?? String(localized: "Profile")
        }
    }

    func edit(_ id: UUID, draft: ManualRuleDraft) async -> Bool {
        await ruleCommand(String(localized: "Edit Rule")) {
            try await controlPlane.editRule(
                id, draft: draft, expectedGeneration: generation
            )
        }
    }

    func create(_ draft: ManualRuleDraft) async -> Bool {
        await ruleCommand(String(localized: "Create Rule")) {
            try await controlPlane.createManualRule(
                draft, expectedGeneration: generation
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
                String(localized: "The change wasn’t saved. Your rules may have changed, so check them and try again.")
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
    func showNotice(_ message: String) { notice = message }

    // MARK: Sharing rules

    /// Selected rules that can go in a file. Rift manages the others.
    var exportableSelectionCount: Int {
        allRules.filter { selection.contains($0.id) && ConfigurationArchiveCodec.isShareable($0) }.count
    }

    func exportSelected() async {
        let count = exportableSelectionCount
        guard count > 0 else { return }
        do {
            let data = try await controlPlane.ruleSetArchiveData(selection)
            try await ArchiveFileAccess.save(
                data: data, suggestedName: count == 1 ? String(localized: "Rift Rule.json") : String(localized: "Rift Rules.json")
            )
        } catch {
            reportNotSaved(ArchiveFileAccess.message(for: error, fallback: String(localized: "The rules couldn’t be exported.")))
        }
    }

    /// Writes the selected rules as a `.lsrules` file other firewalls read,
    /// and says how many the format couldn't hold.
    func exportSelectedAsLSRules() async {
        do {
            let export = try await controlPlane.lsrulesExport(selection)
            let name = export.exported == 1 ? String(localized: "Rift Rule.lsrules") : String(localized: "Rift Rules.lsrules")
            if try await ArchiveFileAccess.save(data: export.data, suggestedName: name) { notice = export.summary }
        } catch LSRulesWriter.ExportError.nothingToExport {
            reportNotSaved(String(localized: "Nothing to export. The .lsrules format can’t express the selected rules, such as temporary rules, rules for one profile, or rules for system processes."))
        } catch {
            reportNotSaved(ArchiveFileAccess.message(for: error, fallback: String(localized: "The rules couldn’t be exported.")))
        }
    }

    func chooseRulesToImport() async {
        do {
            guard let data = try await ArchiveFileAccess.open() else { return }
            let pending = try await controlPlane.previewRuleImport(data)
            guard !pending.plan.rules.isEmpty else {
                reportNotSaved(String(localized: "Nothing to import. \(pending.summary)"))
                return
            }
            pendingImport = pending
        } catch {
            reportNotSaved(ArchiveFileAccess.message(
                for: error,
                fallback: String(localized: "Rift couldn’t read this file. Choose rules exported from Rift, or a .lsrules rule file.")
            ))
        }
    }

    func confirmImport() async {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        do {
            let (result, added) = try await controlPlane.importRules(pending.payload)
            if await focusRuleIDsAfterReload(added) == .loadFailed { await reload() }
            present(result)
        } catch {
            await reload()
            reportNotSaved(String(localized: "The rules weren’t imported. Your rules may have changed, so check them and try again."))
        }
    }

    func cancelImport() { pendingImport = nil }

    func clearFilters() {
        search = ""
        actionFilter = .all
        sidebarSelection = .filter(.all)
    }

    private func reportNotSaved(_ message: String) {
        notice = [message, notice].compactMap { $0 }.joined(separator: " ")
    }
}
