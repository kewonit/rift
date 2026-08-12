import AbyssControl
import AbyssCore
import SwiftUI

struct RulesWorkspaceView: View {
    @Binding var requestedSelection: Set<UUID>
    let artworkStore: ApplicationArtworkStore
    let isPreview: Bool
    @State private var model: RulesWorkspaceController
    @State private var showingEditor = false
    @State private var editingRow: RuleRowViewValue?
    @State private var showingInspector = true
    @State private var showingDeleteConfirmation = false

    init(
        controlPlane: ControlPlaneController,
        requestedSelection: Binding<Set<UUID>>,
        artworkStore: ApplicationArtworkStore,
        isPreview: Bool = false
    ) {
        _requestedSelection = requestedSelection
        self.artworkStore = artworkStore
        self.isPreview = isPreview
        _model = State(initialValue: RulesWorkspaceController(controlPlane: controlPlane))
    }

    var body: some View {
        NavigationSplitView {
            RulesWorkspaceSidebarView(model: model, isPreview: isPreview)
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } content: {
            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    Text(message).frame(maxWidth: .infinity).padding(8).background(.orange.opacity(0.18))
                }
                if isPreview {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                RulesWorkspaceTable(
                    model: model,
                    artworkStore: artworkStore,
                    isPreview: isPreview,
                    editingRow: $editingRow,
                    showingEditor: $showingEditor,
                    showingInspector: $showingInspector,
                    showingDeleteConfirmation: $showingDeleteConfirmation
                )
            }
            .navigationTitle(model.sidebarTitle)
            .navigationSplitViewColumnWidth(min: 440, ideal: 578, max: .infinity)
        } detail: {
            Group {
                if showingInspector, let row = model.selectedRow {
                    RuleInspectorView(
                        row: row,
                        groups: model.groups,
                        profiles: model.profiles,
                        artworkStore: artworkStore
                    )
                } else {
                    ContentUnavailableView("Select a rule", systemImage: "sidebar.right")
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 320)
        }
        .searchable(text: $model.search, prompt: "Search rules")
        .focusedSceneValue(
            \.ruleWorkspaceHistoryAction,
            RuleWorkspaceHistoryAction(
                title: model.historyCommandTitle ?? "Undo Rule Change",
                isRedo: model.historyCommandIsRedo,
                isEnabled: !isPreview
                    && model.historyCommandTitle != nil
                    && !model.historyCommandIsRunning,
                perform: { Task { await model.performHistoryCommand() } }
            )
        )
        .toolbar {
            Menu {
                Picker("Search In", selection: $model.searchScope) {
                    ForEach(RuleSearchScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
            } label: {
                Label("Search Scope", systemImage: "text.magnifyingglass")
            }
            .accessibilityLabel("Search Scope")
            .accessibilityValue(model.searchScope.rawValue)
            .help("Search in \(model.searchScope.rawValue.lowercased()).")
            Menu {
                Picker("Action", selection: $model.actionFilter) {
                    ForEach(RuleActionFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
            } label: {
                Label("Filter by Action", systemImage: "line.3.horizontal.decrease.circle")
            }
            .accessibilityLabel("Action Filter")
            .accessibilityValue(model.actionFilter.rawValue)
            .help(model.actionFilter.rawValue)
            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(RuleWorkspaceSort.allCases) { sort in
                        Text(sort.rawValue).tag(sort)
                    }
                }
            } label: {
                Label("Sort Rules", systemImage: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Sort Rules")
            .accessibilityValue(model.sort.rawValue)
            .help("Sort by \(model.sort.rawValue.lowercased()).")
            Button { Task { await model.performHistoryCommand() } } label: {
                Label(
                    model.historyCommandTitle ?? "Undo Rule Change",
                    systemImage: "arrow.uturn.backward"
                )
            }
            .disabled(
                isPreview || model.historyCommandTitle == nil || model.historyCommandIsRunning
            )
            .help(model.historyCommandTitle ?? "No rule change can be undone.")
            Button { showingEditor = true } label: { Label("Add Rule", systemImage: "plus") }
                .disabled(isPreview || model.historyCommandIsRunning)
            Button { editingRow = model.selectedRow } label: { Label("Edit", systemImage: "pencil") }
                .disabled(
                    isPreview || model.historyCommandIsRunning || !model.selectedRowIsEditable
                )
            Button { Task { await model.setSelectedEnabled(true) } } label: {
                Label("Enable", systemImage: "checkmark.circle")
            }.disabled(
                isPreview || model.historyCommandIsRunning || model.eligibleSelectionCount == 0
            )
            Button { showingDeleteConfirmation = true } label: {
                Label("Delete", systemImage: "trash")
            }.disabled(
                isPreview || model.historyCommandIsRunning || model.eligibleSelectionCount == 0
            )
            Button { showingInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
        }
        .sheet(isPresented: $showingEditor) {
            ManualRuleEditorView(
                identities: model.identityChoices,
                groups: model.groups,
                profiles: model.profiles,
                previewEnvironment: model.previewEnvironment
            ) { draft in await model.create(draft) }
        }
        .sheet(item: $editingRow) { row in
            ManualRuleEditorView(
                initial: row.rule,
                identities: model.identityChoices,
                groups: model.groups,
                profiles: model.profiles,
                previewEnvironment: model.previewEnvironment
            ) { draft in
                await model.edit(row.id, draft: draft)
            }
        }
        .task {
            if requestedSelection.isEmpty {
                await model.reload()
                if isPreview, model.selection.isEmpty, let first = model.rows.first {
                    model.selection = [first.id]
                }
            } else {
                await acceptRequestedSelection()
            }
        }
        .onChange(of: model.sidebarSelection) { _, _ in model.scheduleReload() }
        .onChange(of: model.search) { _, _ in model.scheduleReload() }
        .onChange(of: model.searchScope) { _, _ in model.scheduleReload() }
        .onChange(of: model.actionFilter) { _, _ in model.scheduleReload() }
        .onChange(of: model.sort) { _, _ in model.scheduleReload() }
        .onChange(of: requestedSelection) { _, _ in
            Task { await acceptRequestedSelection() }
        }
        .confirmationDialog(
            "Delete \(model.eligibleSelectionCount) rule(s)?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(model.eligibleSelectionCount) Rule(s)", role: .destructive) {
                Task { await model.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(model.skippedSelectionCount) protected or managed rule(s) will be skipped. This changes new and pending connections only.")
        }
    }

    private func acceptRequestedSelection() async {
        guard !requestedSelection.isEmpty else { return }
        let ids = requestedSelection
        let result: RulesWorkspaceController.RequestedFocusResult
        if isPreview {
            result = model.focusRuleIDs(ids)
        } else {
            result = await model.focusRuleIDsAfterReload(ids)
        }
        if result != .loadFailed { requestedSelection = [] }
    }

}

private struct RuleInspectorView: View {
    let row: RuleRowViewValue
    let groups: [LocalRuleGroup]
    let profiles: [PolicyProfile]
    let artworkStore: ApplicationArtworkStore

    var body: some View {
        Form {
            Section("Rule") {
                if let identity = applicationIdentity(row.rule.process) {
                    HStack(spacing: 9) {
                        ApplicationIdentityIcon(
                            identity: identity,
                            fallbackSystemName: "app.dashed",
                            size: 28,
                            artworkStore: artworkStore
                        )
                        Text(row.conditionSummary).font(.headline)
                    }
                }
                LabeledContent("Action", value: row.actionLabel)
                LabeledContent("Condition", value: row.conditionSummary)
                LabeledContent("Priority", value: priority)
                if let groupID = row.rule.localGroupID {
                    LabeledContent("Local group", value: groupName(groupID))
                }
                if let profileID = row.rule.profileID {
                    LabeledContent("Profile", value: profileName(profileID))
                }
                if row.rule.flags.contains(.sourceManaged) {
                    LabeledContent("Management", value: "Blocklist source")
                }
            }
            Section("Usage") {
                LabeledContent(
                    "Retained uses",
                    value: row.usage.coverage == .complete
                        ? String(row.usage.lowerBoundCount)
                        : "≥\(row.usage.lowerBoundCount)"
                )
                LabeledContent("Coverage", value: row.usage.coverage.rawValue.capitalized)
                if let lastUsedAt = row.usage.lastUsedAt {
                    LabeledContent("Last retained use", value: lastUsedAt.formatted())
                }
            }
            if !row.rule.notes.isEmpty {
                Section("Note") { Text(row.rule.notes) }
            }
            DisclosureGroup("Details") {
                LabeledContent("Revision", value: String(row.rule.revision))
                LabeledContent("Created", value: row.rule.createdAt.formatted())
                LabeledContent("Modified", value: row.rule.modifiedAt.formatted())
                if let groupID = row.rule.localGroupID {
                    LabeledContent("Group ID", value: groupID.uuidString.lowercased())
                }
                if let profileID = row.rule.profileID {
                    LabeledContent("Profile ID", value: profileID.uuidString.lowercased())
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Rule Inspector")
    }

    private var priority: String {
        switch row.rule.priority {
        case .elevatedUser: "User exception"
        case .blocklistDeny: "Blocklist"
        case .normal: "Normal"
        }
    }

    private func groupName(_ id: UUID) -> String {
        groups.first { $0.id == id }?.name ?? "Unavailable"
    }

    private func profileName(_ id: UUID) -> String {
        profiles.first { $0.id == id }?.name ?? "Unavailable"
    }
}
