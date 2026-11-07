import RiftControl
import RiftCore
import SwiftUI

struct RulesWorkspaceView: View {
    @Binding var requestedSelection: Set<UUID>
    let artworkStore: ApplicationArtworkStore
    let isPreview: Bool
    let setupIncomplete: Bool
    let openStatus: () -> Void
    @State private var model: RulesWorkspaceController
    @State private var showingEditor = false
    @State private var editingRow: RuleRowViewValue?
    @State private var showingInspector = true
    @State private var showingDeleteConfirmation = false

    init(
        controlPlane: ControlPlaneController,
        requestedSelection: Binding<Set<UUID>>,
        artworkStore: ApplicationArtworkStore,
        isPreview: Bool = false,
        setupIncomplete: Bool = false,
        openStatus: @escaping () -> Void = {}
    ) {
        _requestedSelection = requestedSelection
        self.artworkStore = artworkStore
        self.isPreview = isPreview
        self.setupIncomplete = setupIncomplete
        self.openStatus = openStatus
        _model = State(initialValue: RulesWorkspaceController(controlPlane: controlPlane))
    }

    var body: some View {
        HSplitView {
            RulesWorkspaceSidebarView(model: model, isPreview: isPreview)
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 220)
                .frame(maxHeight: .infinity)

            VStack(spacing: 0) {
                if let message = model.errorMessage, !setupIncomplete {
                    HStack(spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Try Again") { Task { await model.reload() } }
                    }
                    .padding(8)
                    .background(.orange.opacity(0.18))
                }
                if let notice = model.notice {
                    HStack(spacing: 10) {
                        Label(notice, systemImage: "info.circle")
                        Spacer()
                        Button("Dismiss") { model.dismissNotice() }
                    }
                    .padding(8)
                    .background(.orange.opacity(0.12))
                }
                if model.errorMessage == nil {
                    RulesWorkspaceTable(
                        model: model,
                        artworkStore: artworkStore,
                        isPreview: isPreview,
                        editingRow: $editingRow,
                        showingEditor: $showingEditor,
                        showingInspector: $showingInspector,
                        showingDeleteConfirmation: $showingDeleteConfirmation
                    )
                } else if setupIncomplete {
                    ContentUnavailableView {
                        Label("Finish Setup First", systemImage: "list.bullet.rectangle")
                    } description: {
                        Text("You can add rules once the network filter is on.")
                    } actions: {
                        Button("Show Status", action: openStatus)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Rules aren’t available right now",
                        systemImage: "exclamationmark.triangle"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 400, idealWidth: 560, maxWidth: .infinity)
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: $showingInspector) {
            Group {
                if let row = model.selectedRow, model.errorMessage == nil {
                    RuleInspectorView(
                        row: row,
                        groups: model.groups,
                        profiles: model.profiles,
                        blocklists: model.blocklists,
                        artworkStore: artworkStore
                    )
                } else {
                    ContentUnavailableView("No Rule Selected", systemImage: "list.bullet.rectangle")
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .navigationTitle(model.sidebarTitle)
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search rules")
        .searchScopes($model.searchScope) {
            ForEach(RuleSearchScope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .onDeleteCommand {
            guard !isPreview, !model.historyCommandIsRunning, model.eligibleSelectionCount > 0 else { return }
            showingDeleteConfirmation = true
        }
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
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Show", selection: $model.actionFilter) {
                        ForEach(RuleActionFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    Picker("Sort By", selection: $model.sort) {
                        ForEach(RuleWorkspaceSort.allCases) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                } label: {
                    Label("Filter and Sort", systemImage: model.actionFilter == .all
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter and sort rules")
                Button { showingEditor = true } label: { Label("Add Rule", systemImage: "plus") }
                    .disabled(isPreview || model.historyCommandIsRunning)
                    .help("Add a rule")
                Button { showingInspector.toggle() } label: {
                    Label(showingInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
                }
                .help(showingInspector ? "Hide the inspector" : "Show the inspector")
            }
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
            model.eligibleSelectionCount == 1
                ? "Delete 1 rule?" : "Delete \(model.eligibleSelectionCount) rules?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                model.eligibleSelectionCount == 1
                    ? "Delete Rule" : "Delete \(model.eligibleSelectionCount) Rules",
                role: .destructive
            ) {
                Task { await model.deleteSelected() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteMessage: String {
        let note = "This only affects new connections and ones waiting for a decision."
        switch model.skippedSelectionCount {
        case 0: return note
        case 1: return "1 protected or blocklist rule will be skipped. " + note
        case let count: return "\(count) protected or blocklist rules will be skipped. " + note
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
