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
    @State var nodeSelection: Set<RuleWorkspaceNodeID> = []
    @State var contextMessage: String?
    @State var focusedApplication: ProcessIdentity?

    var body: some View {
        Table(displayedHierarchy, children: \.children, selection: tableSelection) {
            TableColumn("App / Rule") { node in
                identityCell(node)
            }
            .width(min: 160, ideal: 190)
            TableColumn("On") { node in
                if canToggle(node) {
                    Toggle(enabledLabel(node), isOn: Binding(
                        get: { rows(node).allSatisfy(\.rule.isEnabled) },
                        set: { value in
                            applySelection([node.id])
                            Task { await model.setSelectedEnabled(value) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                } else {
                    Image(systemName: enabledSymbol(node))
                        .foregroundStyle(enabledColor(node))
                        .accessibilityLabel(enabledLabel(node))
                        .help("Protected and blocklist rules can’t be turned off here.")
                }
            }
            .width(34)
            TableColumn("Action") { node in Text(action(node)) }
                .width(min: 60, ideal: 70)
            TableColumn("Scope") { node in Text(scope(node)) }
                .width(min: 80, ideal: 96)
            TableColumn("Source") { node in Text(source(node)) }
                .width(min: 64, ideal: 76)
            TableColumn("Uses") { node in
                Text(usage(node)).monospacedDigit().help(usageHelp(node))
            }
            .width(55)
            .alignment(.trailing)
            TableColumn("Status") { node in Text(state(node)) }
                .width(min: 60, ideal: 70)
        }
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: RuleWorkspaceNodeID.self) { ids in
            contextMenuItems(ids)
        } primaryAction: { ids in
            let selected = applySelection(ids)
            if selected.count == 1, selectionIsEditable(ids), !isPreview {
                editingRow = row(selected.first)
            } else {
                showingInspector = true
            }
        }
        .accessibilityActions {
            if selectedApplicationIdentity(nodeSelection) != nil {
                Button("Show Rules for This App") { focusAffectingRules(nodeSelection) }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let focusedApplication {
                HStack(spacing: 6) {
                    Label(
                        "Rules for \(RuleWorkspacePresentation.identity(focusedApplication))",
                        systemImage: "scope"
                    )
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Button { self.focusedApplication = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Show All Rules")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.bar)
                .help("Showing rules that can apply to this app. Each rule’s other conditions still apply.")
            }
        }
        .disabled(model.historyCommandIsRunning)
        .overlay {
            if !model.hasLoaded {
                ProgressView()
            } else if model.rows.isEmpty, model.allRules.isEmpty {
                ContentUnavailableView {
                    Label("No Rules Yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Add a rule here, or block something from the Map.")
                } actions: {
                    Button("Add Rule") { showingEditor = true }.disabled(isPreview)
                }
            } else if model.rows.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Rules", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing matches your search and filters.")
                } actions: {
                    Button("Clear Filters") { model.clearFilters() }
                }
            }
        }
        .onAppear { synchronizeSelection() }
        .onChange(of: model.selection) { _, _ in synchronizeSelection() }
        .onChange(of: model.rows) { _, _ in synchronizeSelection() }
        .alert(
            "Couldn’t complete this action",
            isPresented: Binding(
                get: { contextMessage != nil },
                set: { if !$0 { contextMessage = nil } }
            )
        ) {
            Button("OK") { contextMessage = nil }
        } message: {
            Text(contextMessage ?? "Try again.")
        }
    }

    @ViewBuilder
    func identityCell(_ node: RuleWorkspaceNode) -> some View {
        let cell = HStack(spacing: 7) {
            if node.row == nil {
                if let identity = node.applicationIdentity {
                    ApplicationIdentityIcon(
                        identity: identity,
                        fallbackSystemName: "app.dashed",
                        size: 16,
                        artworkStore: artworkStore
                    )
                } else {
                    Image(systemName: "square.stack.3d.up").frame(width: 16, height: 16)
                }
            }
            if node.row == nil, let identity = node.applicationIdentity {
                ApplicationNameText(
                    identity: identity,
                    fallback: MonitorQuery.identityLabel(identity),
                    artworkStore: artworkStore
                )
                .lineLimit(1)
            } else {
                Text(node.title).lineLimit(1)
            }
            if let subtitle = node.subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .help([node.title, node.applicationIdentity?.signerKind, node.subtitle].compactMap { $0 }.joined(separator: " — "))
        .accessibilityElement(children: .combine)
        .accessibilityValue(node.row == nil ? ruleCountLabel(node.ruleIDs.count) : "")

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

    var tableSelection: Binding<Set<RuleWorkspaceNodeID>> {
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

    func synchronizeSelection() {
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
    func applySelection(_ ids: Set<RuleWorkspaceNodeID>) -> Set<UUID> {
        let selected = selectedRuleIDs(ids)
        model.selectRulesImmediately(selected)
        return selected
    }

    func selectedRuleIDs(_ ids: Set<RuleWorkspaceNodeID>) -> Set<UUID> {
        RuleWorkspaceHierarchy.ruleIDs(for: ids, in: displayedHierarchy)
    }

    func selectedRows(_ ids: Set<RuleWorkspaceNodeID>) -> [RuleRowViewValue] {
        let selected = selectedRuleIDs(ids)
        return model.rows.filter { selected.contains($0.id) }
    }

    func draggableRuleIDs(for node: RuleWorkspaceNode) -> Set<UUID>? {
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

    func row(_ id: UUID?) -> RuleRowViewValue? {
        id.flatMap { id in model.rows.first { $0.id == id } }
    }

    func selectionIsEditable(_ ids: Set<RuleWorkspaceNodeID>) -> Bool {
        let rows = selectedRows(ids)
        return rows.count == 1
            && !rows[0].rule.flags.contains(.protected)
            && !rows[0].rule.flags.contains(.sourceManaged)
    }

    func eligibleCount(_ ids: Set<RuleWorkspaceNodeID>) -> Int {
        selectedRows(ids).filter {
            !$0.rule.flags.contains(.protected) && !$0.rule.flags.contains(.sourceManaged)
        }.count
    }

    func selectedApplicationIdentity(
        _ ids: Set<RuleWorkspaceNodeID>
    ) -> ProcessIdentity? {
        let identities = Set(selectedRows(ids).compactMap { applicationIdentity($0.rule.process) })
        return identities.count == 1 ? identities.first : nil
    }

    var displayedHierarchy: [RuleWorkspaceNode] {
        guard let focusedApplication else { return model.hierarchy }
        return RuleWorkspaceHierarchy.nodes(
            affecting: focusedApplication,
            in: model.hierarchy
        )
    }

    func focusAffectingRules(_ ids: Set<RuleWorkspaceNodeID>) {
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

    func revealApplication(_ ids: Set<RuleWorkspaceNodeID>) {
        guard let identity = selectedApplicationIdentity(ids) else { return }
        Task {
            guard await artworkStore.revealApplication(for: identity) else {
                contextMessage = "Rift couldn’t find exactly one installed copy of this app."
                return
            }
        }
    }

    func copyDetails(_ ids: Set<RuleWorkspaceNodeID>) {
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
            contextMessage = "Rift couldn’t copy the rule details. Try again."
            return
        }
    }
}
