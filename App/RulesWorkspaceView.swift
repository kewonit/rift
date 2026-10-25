import RiftControl
import RiftCore
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
        HSplitView {
            RulesWorkspaceSidebarView(model: model, isPreview: isPreview)
                .frame(minWidth: 160, idealWidth: 190, maxWidth: 220)
                .frame(maxHeight: .infinity)

            VStack(spacing: 0) {
                if let message = model.errorMessage {
                    HStack(spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Try Again") { Task { await model.reload() } }
                    }
                    .padding(8)
                    .background(.orange.opacity(0.18))
                }
                if isPreview {
                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
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

            if showingInspector, model.errorMessage == nil {
                Group {
                    if let row = model.selectedRow {
                        RuleInspectorView(
                            row: row,
                            groups: model.groups,
                            profiles: model.profiles,
                            blocklists: model.blocklists,
                            artworkStore: artworkStore
                        )
                    } else {
                        ContentUnavailableView("Select a rule", systemImage: "sidebar.right")
                    }
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 320)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.sidebarTitle)
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
            .accessibilityLabel("Filter by Action")
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
            .help(model.historyCommandTitle ?? "Nothing to undo")
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

private struct RuleInspectorView: View {
    let row: RuleRowViewValue
    let groups: [LocalRuleGroup]
    let profiles: [PolicyProfile]
    let blocklists: [BlocklistSource]
    let artworkStore: ApplicationArtworkStore

    var body: some View {
        Form {
            Section("Rule") {
                HStack(spacing: 9) {
                    if let identity = applicationIdentity(row.rule.process) {
                        ApplicationIdentityIcon(
                            identity: identity,
                            fallbackSystemName: "app.dashed",
                            size: 28,
                            artworkStore: artworkStore
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.applicationLabel).font(.headline)
                        Text(row.conditionSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Action", value: row.actionLabel)
                LabeledContent("Enabled", value: row.rule.isEnabled ? "Yes" : "No")
                LabeledContent("Review", value: reviewState)
                LabeledContent("Priority", value: priority)
                LabeledContent("Status", value: enforcementState)
                if let groupID = row.rule.localGroupID {
                    LabeledContent("Group", value: groupName(groupID))
                }
                if let profileID = row.rule.profileID {
                    LabeledContent("Profile", value: profileName(profileID))
                }
                if row.rule.flags.contains(.sourceManaged) {
                    LabeledContent("Managed by", value: "Blocklist")
                }
                if row.rule.flags.contains(.protected) {
                    LabeledContent("Protection", value: "Protected")
                }
            }
            Section("Matches") {
                LabeledContent("Destination", value: destinationLabel)
                LabeledContent("Protocol", value: protocolLabel)
                LabeledContent("Port", value: portLabel)
                LabeledContent("Direction", value: row.rule.direction.rawValue.capitalized)
                LabeledContent("Owner", value: ownerLabel)
            }
            Section("App Identity") {
                identityDetails(row.rule.process)
            }
            Section("Source & Expiration") {
                LabeledContent("Source", value: sourceLabel)
                if let expiresAt = row.rule.expiresAt {
                    LabeledContent("Expires", value: expiresAt.formatted())
                } else {
                    LabeledContent("Expires", value: "Never")
                }
            }
            Section("Usage") {
                LabeledContent(
                    "Times used",
                    value: row.usage.coverage == .complete
                        ? String(row.usage.lowerBoundCount)
                        : "≥\(row.usage.lowerBoundCount)"
                )
                LabeledContent("Usage history", value: usageCoverage)
                if let lastUsedAt = row.usage.lastUsedAt {
                    LabeledContent("Last used", value: lastUsedAt.formatted())
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
        case .elevatedUser: "Blocklist exception"
        case .blocklistDeny: "Blocklist"
        case .normal: "Normal"
        }
    }

    private var usageCoverage: String {
        switch row.usage.coverage {
        case .complete: "Complete"
        case .partial, .gap: "Incomplete"
        }
    }

    private var reviewState: String {
        row.rule.reviewState == .reviewed ? "Reviewed" : "Needs review"
    }

    private var enforcementState: String {
        switch row.enforcementState {
        case .enforced: "Active"
        case .savedPendingEnforcement: "Saved, waiting for the filter"
        case .persistedPendingProvider: "Saved, waiting for the filter to start"
        case .applyFailed: "Couldn’t apply"
        }
    }

    private var destinationLabel: String {
        switch row.rule.destination {
        case .ipSet(let values): values.map(\.description).joined(separator: ", ")
        case .exactHostnameSet(let values): values.map(\.ascii).joined(separator: ", ")
        case .domainSet(let values): values.map { "*." + $0.ascii }.joined(separator: ", ")
        case .endpointClass(let value): RuleWorkspacePresentation.endpointClass(value)
        case .anyEndpoint: "Any destination"
        }
    }

    private var protocolLabel: String {
        switch row.rule.transportProtocol {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .anySupportedProtocol: "TCP or UDP"
        }
    }

    private var portLabel: String {
        guard let port = row.rule.port else { return "Any port" }
        return port.lowerBound == port.upperBound
            ? String(port.lowerBound) : "\(port.lowerBound)–\(port.upperBound)"
    }

    private var ownerLabel: String {
        switch row.rule.owner {
        case .authorizedUser: "Your account"
        case .specificUser(let uid): "User ID \(uid)"
        case .system: "System"
        }
    }

    private var sourceLabel: String {
        switch row.rule.source {
        case .manual: "Manual"
        case .imported: "Imported"
        case .feature(let identifier): "Rift feature · \(identifier)"
        case .blocklist(let sourceID):
            blocklists.first { $0.id == sourceID }?.name ?? "Removed blocklist"
        }
    }

    @ViewBuilder
    private func identityDetails(_ condition: ProcessCondition) -> some View {
        switch condition {
        case .anyProcess:
            LabeledContent("App", value: "Any app")
        case .exact(let identity):
            identityRows(identity, label: "App")
        case .appViaHelper(let app, let helper):
            identityRows(app, label: "App")
            identityRows(helper, label: "Helper process")
        }
    }

    @ViewBuilder
    private func identityRows(_ identity: ProcessIdentity, label: String) -> some View {
        LabeledContent(label, value: MonitorQuery.identityLabel(identity))
        switch identity {
        case .applePlatform(let signed):
            signedRows(signed, kind: "Apple")
        case .developerID(let signed):
            signedRows(signed, kind: "Developer ID")
        case .appStore(let signed):
            signedRows(signed, kind: "Mac App Store")
        case .otherSigner(let hash, let identifier):
            LabeledContent("Signature", value: "Other developer")
            LabeledContent("Signing ID", value: identifier)
            LabeledContent("Public-key hash", value: hash.description)
        case .adHoc(let hash):
            LabeledContent("Signature", value: "Ad hoc")
            LabeledContent("Code hash", value: hash.description)
        case .unsigned(let path, let hash):
            LabeledContent("Signature", value: "Unsigned")
            LabeledContent("Path", value: path)
            LabeledContent("File hash", value: hash.description)
        }
    }

    @ViewBuilder
    private func signedRows(_ value: SignedCodeIdentity, kind: String) -> some View {
        LabeledContent("Signature", value: kind)
        LabeledContent("Signing ID", value: value.signingIdentifier)
        if let team = value.teamIdentifier {
            LabeledContent("Team ID", value: team)
        }
    }

    private func groupName(_ id: UUID) -> String {
        groups.first { $0.id == id }?.name ?? "Removed group"
    }

    private func profileName(_ id: UUID) -> String {
        profiles.first { $0.id == id }?.name ?? "Removed profile"
    }
}
