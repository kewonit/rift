import RiftControl
import RiftCore
import AppKit
import SwiftUI

struct RulesWorkspaceTable: View {
    @Bindable var model: RulesWorkspaceController
    let artworkStore: ApplicationArtworkStore
    let isPreview: Bool
    @Binding var editingRow: RuleRowViewValue?
    @Binding var showingEditor: Bool
    @Binding var showingInspector: Bool
    @Binding var showingDeleteConfirmation: Bool
    @State private var nodeSelection: Set<RuleWorkspaceNodeID> = []
    @State private var contextMessage: String?
    @State private var focusedApplication: ProcessIdentity?

    var body: some View {
        Table(displayedHierarchy, children: \.children, selection: tableSelection) {
            TableColumn("Application / Condition") { node in
                identityCell(node)
            }
            .width(min: 190, ideal: 260)
            TableColumn("On") { node in
                Image(systemName: enabledSymbol(node))
                    .accessibilityLabel(enabledLabel(node))
            }
            .width(34)
            TableColumn("Action") { node in Text(action(node)) }
                .width(min: 70, ideal: 85)
            TableColumn("Scope") { node in Text(scope(node)) }
                .width(min: 90, ideal: 125)
            TableColumn("Source") { node in Text(source(node)) }
                .width(min: 75, ideal: 105)
            TableColumn("Use") { node in
                Text(usage(node)).help(usageHelp(node))
            }
            .width(55)
            TableColumn("State") { node in Text(state(node)) }
                .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: RuleWorkspaceNodeID.self) { ids in
            Button("New Rule…") { showingEditor = true }
                .disabled(isPreview)
            Divider()
            Button("Edit") {
                let selected = applySelection(ids)
                editingRow = selected.count == 1 ? row(selected.first) : nil
            }
            .disabled(isPreview || !selectionIsEditable(ids))
            Button("Duplicate") {
                applySelection(ids)
                Task { await model.duplicateSelected() }
            }
            .disabled(isPreview || !selectionIsEditable(ids))
            Button("Enable") {
                applySelection(ids)
                Task { await model.setSelectedEnabled(true) }
            }
            .disabled(isPreview || eligibleCount(ids) == 0)
            Button("Disable") {
                applySelection(ids)
                Task { await model.setSelectedEnabled(false) }
            }
            .disabled(isPreview || eligibleCount(ids) == 0)
            Button("Mark Reviewed") {
                applySelection(ids)
                Task { await model.markSelectedReviewed(true) }
            }
            .disabled(isPreview || eligibleCount(ids) == 0)
            Button("Mark Unreviewed") {
                applySelection(ids)
                Task { await model.markSelectedReviewed(false) }
            }
            .disabled(isPreview || eligibleCount(ids) == 0)
            Menu("Assign to Group") {
                Button("No Group") {
                    applySelection(ids)
                    Task { await model.assignSelectedToGroup(nil) }
                }
                ForEach(model.groups) { group in
                    Button(group.name) {
                        applySelection(ids)
                        Task { await model.assignSelectedToGroup(group.id) }
                    }
                }
            }
            .disabled(isPreview || eligibleCount(ids) == 0)
            Menu("Assign to Profile") {
                Button("All Profiles") {
                    applySelection(ids)
                    Task { await model.assignSelectedToProfile(nil) }
                }
                ForEach(model.profiles) { profile in
                    Button(profile.name) {
                        applySelection(ids)
                        Task { await model.assignSelectedToProfile(profile.id) }
                    }
                }
            }
            .disabled(isPreview || eligibleCount(ids) == 0)
            Divider()
            Button("Show Affecting Rules") { focusAffectingRules(ids) }
                .disabled(selectedApplicationIdentity(ids) == nil)
            Button("Reveal Application") { revealApplication(ids) }
                .disabled(isPreview || selectedApplicationIdentity(ids) == nil)
            Button("Copy Details") { copyDetails(ids) }
                .disabled(isPreview || selectedRows(ids).count != 1)
            Divider()
            Button("Delete…", role: .destructive) {
                applySelection(ids)
                showingDeleteConfirmation = true
            }
            .disabled(isPreview || eligibleCount(ids) == 0)
            let skipped = selectedRuleIDs(ids).count - eligibleCount(ids)
            if skipped > 0 {
                Text("\(skipped) protected or managed rule(s) will be skipped.")
            }
        } primaryAction: { ids in
            applySelection(ids)
            showingInspector = true
        }
        .accessibilityActions {
            if selectedApplicationIdentity(nodeSelection) != nil {
                Button("Show Affecting Rules") { focusAffectingRules(nodeSelection) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let focusedApplication {
                HStack(spacing: 6) {
                    Label(
                        "Affecting \(RuleWorkspacePresentation.identity(focusedApplication))",
                        systemImage: "scope"
                    )
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Button { self.focusedApplication = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Clear application focus")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.bar)
                .help("Rules whose application scope can include this application. Other conditions still apply.")
            }
        }
        .disabled(model.historyCommandIsRunning)
        .overlay {
            if model.rows.isEmpty {
                ContentUnavailableView("No matching rules", systemImage: "list.bullet.rectangle")
            }
        }
        .onAppear { synchronizeSelection() }
        .onChange(of: model.selection) { _, _ in synchronizeSelection() }
        .onChange(of: model.rows) { _, _ in synchronizeSelection() }
        .alert(
            "Command Unavailable",
            isPresented: Binding(
                get: { contextMessage != nil },
                set: { if !$0 { contextMessage = nil } }
            )
        ) {
            Button("OK") { contextMessage = nil }
        } message: {
            Text(contextMessage ?? "The command could not be completed.")
        }
    }

    @ViewBuilder
    private func identityCell(_ node: RuleWorkspaceNode) -> some View {
        let cell = HStack(spacing: 7) {
            if node.row == nil {
                if let identity = node.applicationIdentity {
                    ApplicationIdentityIcon(
                        identity: identity,
                        fallbackSystemName: "app.dashed",
                        size: 18,
                        artworkStore: artworkStore
                    )
                } else {
                    Image(systemName: "square.stack.3d.up").frame(width: 18, height: 18)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .help([node.title, node.subtitle].compactMap { $0 }.joined(separator: " — "))
        .accessibilityElement(children: .combine)
        .accessibilityValue(node.row == nil ? "\(node.ruleIDs.count) rules" : "")

        if let ruleIDs = draggableRuleIDs(for: node) {
            cell
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onDrag {
                    RuleWorkspaceDragRegistry.shared.issue(
                        ruleIDs: ruleIDs,
                        generation: model.generation
                    ).itemProvider()
                }
        } else {
            cell
        }
    }

    private var tableSelection: Binding<Set<RuleWorkspaceNodeID>> {
        Binding(
            get: { nodeSelection },
            set: { value in
                nodeSelection = value
                model.deferTableSelection(
                    RuleWorkspaceHierarchy.ruleIDs(for: value, in: displayedHierarchy)
                )
            }
        )
    }

    private func synchronizeSelection() {
        if let focusedApplication,
           !model.hierarchy.contains(where: { $0.applicationIdentity == focusedApplication }) {
            self.focusedApplication = nil
        }
        if focusedApplication != nil, !model.selection.isEmpty {
            let focusedRuleIDs = Set(displayedHierarchy.flatMap(\.ruleIDs))
            if !model.selection.isSubset(of: focusedRuleIDs) {
                focusedApplication = nil
            }
        }
        let hierarchy = displayedHierarchy
        let validNodeIDs = Set(hierarchy.flatMap { node in
            [node.id] + (node.children ?? []).map(\.id)
        })
        let retained = nodeSelection.intersection(validNodeIDs)
        if RuleWorkspaceHierarchy.ruleIDs(for: retained, in: hierarchy) == model.selection {
            nodeSelection = retained
        } else {
            var represented: Set<UUID> = []
            var external: Set<RuleWorkspaceNodeID> = []
            for node in hierarchy where !node.ruleIDs.isEmpty
                && node.ruleIDs.isSubset(of: model.selection) {
                external.insert(node.id)
                represented.formUnion(node.ruleIDs)
            }
            external.formUnion(model.selection.subtracting(represented).map(RuleWorkspaceNodeID.rule))
            nodeSelection = external.intersection(validNodeIDs)
        }
    }

    @discardableResult
    private func applySelection(_ ids: Set<RuleWorkspaceNodeID>) -> Set<UUID> {
        let selected = selectedRuleIDs(ids)
        model.selectRulesImmediately(selected)
        return selected
    }

    private func selectedRuleIDs(_ ids: Set<RuleWorkspaceNodeID>) -> Set<UUID> {
        RuleWorkspaceHierarchy.ruleIDs(for: ids, in: displayedHierarchy)
    }

    private func selectedRows(_ ids: Set<RuleWorkspaceNodeID>) -> [RuleRowViewValue] {
        let selected = selectedRuleIDs(ids)
        return model.rows.filter { selected.contains($0.id) }
    }

    private func draggableRuleIDs(for node: RuleWorkspaceNode) -> Set<UUID>? {
        let ids = nodeSelection.contains(node.id)
            ? selectedRuleIDs(nodeSelection)
            : node.ruleIDs
        let containsEligibleRule = model.rows.contains { row in
            ids.contains(row.id)
                && !row.rule.flags.contains(.protected)
                && !row.rule.flags.contains(.sourceManaged)
        }
        return containsEligibleRule ? ids : nil
    }

    private func row(_ id: UUID?) -> RuleRowViewValue? {
        id.flatMap { id in model.rows.first { $0.id == id } }
    }

    private func selectionIsEditable(_ ids: Set<RuleWorkspaceNodeID>) -> Bool {
        let rows = selectedRows(ids)
        return rows.count == 1
            && !rows[0].rule.flags.contains(.protected)
            && !rows[0].rule.flags.contains(.sourceManaged)
    }

    private func eligibleCount(_ ids: Set<RuleWorkspaceNodeID>) -> Int {
        selectedRows(ids).filter {
            !$0.rule.flags.contains(.protected) && !$0.rule.flags.contains(.sourceManaged)
        }.count
    }

    private func selectedApplicationIdentity(
        _ ids: Set<RuleWorkspaceNodeID>
    ) -> ProcessIdentity? {
        let identities = Set(selectedRows(ids).compactMap { applicationIdentity($0.rule.process) })
        return identities.count == 1 ? identities.first : nil
    }

    private var displayedHierarchy: [RuleWorkspaceNode] {
        guard let focusedApplication else { return model.hierarchy }
        return RuleWorkspaceHierarchy.nodes(
            affecting: focusedApplication,
            in: model.hierarchy
        )
    }

    private func focusAffectingRules(_ ids: Set<RuleWorkspaceNodeID>) {
        guard let identity = selectedApplicationIdentity(ids) else { return }
        applySelection(ids)
        focusedApplication = identity
        model.sidebarSelection = .filter(.all)
        model.search = ""
        model.searchScope = .all
        model.actionFilter = .all
        model.sort = .automatic
        model.scheduleReload()
    }

    private func revealApplication(_ ids: Set<RuleWorkspaceNodeID>) {
        guard let identity = selectedApplicationIdentity(ids) else { return }
        Task {
            guard await artworkStore.revealApplication(for: identity) else {
                contextMessage = "The installed application could not be verified uniquely."
                return
            }
        }
    }

    private func copyDetails(_ ids: Set<RuleWorkspaceNodeID>) {
        guard let row = selectedRows(ids).only else { return }
        let context = RuleWorkspaceQueryContext(
            activeProfileID: model.activeProfileID,
            enabledLocalGroupIDs: Set(model.groups.filter(\.isEnabled).map(\.id)),
            localGroupNames: Dictionary(
                model.groups.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
            ),
            profileNames: Dictionary(
                model.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
            ),
            blocklistNames: Dictionary(
                model.blocklists.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }
            ),
            now: Date()
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(
            RuleWorkspaceCopyDetails.text(for: row.rule, context: context),
            forType: .string
        ) else {
            contextMessage = "Rule details could not be copied."
            return
        }
    }

    private func rows(_ node: RuleWorkspaceNode) -> [RuleRowViewValue] {
        if let row = node.row { return [row] }
        return node.children?.compactMap(\.row) ?? []
    }

    private func enabledSymbol(_ node: RuleWorkspaceNode) -> String {
        let values = rows(node).map(\.rule.isEnabled)
        if values.allSatisfy({ $0 }) { return "checkmark.circle.fill" }
        if values.allSatisfy({ !$0 }) { return "circle" }
        return "minus.circle.fill"
    }

    private func enabledLabel(_ node: RuleWorkspaceNode) -> String {
        switch enabledSymbol(node) {
        case "checkmark.circle.fill": "Enabled"
        case "circle": "Disabled"
        default: "Mixed enabled state"
        }
    }

    private func action(_ node: RuleWorkspaceNode) -> String {
        node.row?.actionLabel ?? "\(node.ruleIDs.count) rules"
    }

    private func scope(_ node: RuleWorkspaceNode) -> String {
        uniform(rows(node).map(scope))
    }

    private func scope(_ row: RuleRowViewValue) -> String {
        let profile = row.rule.profileID.flatMap { id in
            model.profiles.first { $0.id == id }?.name
        } ?? "All profiles"
        let group = row.rule.localGroupID.flatMap { id in
            model.groups.first { $0.id == id }?.name
        }
        return DisplaySanitizer.plainText(group.map { "\(profile) • \($0)" } ?? profile)
    }

    private func source(_ node: RuleWorkspaceNode) -> String {
        uniform(rows(node).map(source))
    }

    private func source(_ row: RuleRowViewValue) -> String {
        if row.rule.flags.contains(.protected) { return "Protected" }
        switch row.rule.priority {
        case .elevatedUser: return "Exception"
        case .blocklistDeny: return "Blocklist"
        case .normal: return "Manual"
        }
    }

    private func usage(_ node: RuleWorkspaceNode) -> String {
        let values = rows(node)
        var total = 0
        for row in values {
            let next = total.addingReportingOverflow(row.usage.lowerBoundCount)
            guard !next.overflow else { return "—" }
            total = next.partialValue
        }
        return values.allSatisfy { $0.usage.coverage == .complete } ? String(total) : "≥\(total)"
    }

    private func usageHelp(_ node: RuleWorkspaceNode) -> String {
        let values = rows(node)
        if values.allSatisfy({ $0.usage.coverage == .complete }) {
            return "Retained usage is complete for the available history window."
        }
        return "A lower bound because some retained history is incomplete."
    }

    private func state(_ node: RuleWorkspaceNode) -> String {
        uniform(rows(node).map { state($0.enforcementState) })
    }

    private func state(_ state: PolicyOutboxState) -> String {
        switch state {
        case .savedPendingEnforcement: "Saved"
        case .persistedPendingProvider: "Persisted"
        case .enforced: "Enforced"
        case .applyFailed: "Apply failed"
        }
    }

    private func uniform(_ values: [String]) -> String {
        guard let first = values.first else { return "—" }
        return values.dropFirst().allSatisfy { $0 == first } ? first : "Mixed"
    }
}

func applicationIdentity(_ condition: ProcessCondition) -> ProcessIdentity? {
    switch condition {
    case .exact(let identity): identity
    case .appViaHelper(let app, _): app
    case .anyProcess: nil
    }
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
