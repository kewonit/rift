import AbyssControl
import AbyssCore
import SwiftUI

enum RulesSidebarSelection: Hashable {
    case filter(RuleListFilter)
    case profile(UUID)
    case group(UUID)
    case blocklist(UUID)

    var listFilter: RuleListFilter {
        if case .filter(let filter) = self { return filter }
        return .all
    }

    var collectionFilter: RuleCollectionFilter {
        switch self {
        case .filter:
            .all
        case .profile(let id):
            .profile(id)
        case .group(let id):
            .localGroup(id)
        case .blocklist(let id):
            .blocklist(id)
        }
    }

    func includes(_ rule: Rule) -> Bool {
        switch self {
        case .filter:
            false
        case .profile(let id):
            rule.profileID == id
        case .group(let id):
            rule.localGroupID == id
        case .blocklist(let id):
            rule.source == .blocklist(sourceID: id)
        }
    }
}

struct RulesWorkspaceSidebarView: View {
    @Bindable var model: RulesWorkspaceController
    let isPreview: Bool
    @State private var editor: RuleDefinitionEditor?
    @State private var pendingRemoval: RuleDefinitionRemoval?
    @State private var pendingDrop: RuleWorkspaceDropRequest?
    @State private var activeDropTarget: RulesSidebarSelection?
    @State private var showingBlocklistImport = false

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Section {
                ForEach(RuleListFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: symbol(filter))
                        .tag(RulesSidebarSelection.filter(filter))
                }
            }
            if !model.profiles.isEmpty {
                Section("Profiles") {
                    ForEach(model.profiles) { profile in profileRow(profile) }
                }
            }
            if !model.groups.isEmpty {
                Section("Groups") {
                    ForEach(model.groups) { group in groupRow(group) }
                }
            }
            if !model.blocklists.isEmpty {
                Section("Blocklists") {
                    ForEach(model.blocklists) { source in blocklistRow(source) }
                }
            }
        }
        .navigationTitle("Rules")
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Menu {
                    Button("New Profile…") { editor = .newProfile }
                    Button("New Group…") { editor = .newGroup }
                    Divider()
                    Button("Import Local Blocklist…") { showingBlocklistImport = true }
                } label: {
                    Label("Add Collection", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isPreview)
                Spacer()
                Label(policyState, systemImage: policyStateSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Current desired policy state")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
        .sheet(item: $editor) { value in
            RuleDefinitionEditorSheet(editor: value) { name, note, mode in
                switch value {
                case .newProfile:
                    await model.createProfile(name: name)
                case .profile(let profile):
                    await model.updateProfile(
                        profile.id,
                        name: name,
                        operationModeOverride: mode
                    )
                case .newGroup:
                    await model.createGroup(name: name)
                case .group(let group):
                    await model.updateGroup(group.id, name: name, note: note)
                }
            }
        }
        .sheet(isPresented: $showingBlocklistImport) {
            RuleBlocklistImportSheet(model: model)
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            removalButtons(removal)
        } message: { removal in
            Text(removalMessage(removal))
        }
        .confirmationDialog(
            pendingDrop?.title ?? "Reorganize rules?",
            isPresented: Binding(
                get: { pendingDrop != nil },
                set: { if !$0 { pendingDrop = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDrop
        ) { request in
            Button(request.actionTitle) {
                pendingDrop = nil
                Task { await model.performRuleDrop(request) }
            }
            .disabled(isPreview)
            Button("Cancel", role: .cancel) { pendingDrop = nil }
        } message: { request in
            Text(request.message)
        }
    }

    private func profileRow(_ profile: PolicyProfile) -> some View {
        HStack(spacing: 7) {
            Label(display(profile.name), systemImage: "person.crop.circle")
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await model.activateProfile(model.activeProfileID == profile.id ? nil : profile.id) }
            } label: {
                Image(systemName: model.activeProfileID == profile.id
                    ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .disabled(isPreview)
            .accessibilityLabel(model.activeProfileID == profile.id
                ? "Deactivate \(display(profile.name))" : "Activate \(display(profile.name))")
        }
        .tag(RulesSidebarSelection.profile(profile.id))
        .contextMenu {
            Button(model.activeProfileID == profile.id ? "Use Base Profile" : "Activate") {
                Task { await model.activateProfile(model.activeProfileID == profile.id ? nil : profile.id) }
            }
            .disabled(isPreview)
            Button("Edit…") { editor = .profile(profile) }
                .disabled(isPreview)
            Divider()
            Button("Remove…", role: .destructive) {
                pendingRemoval = .profile(profile, model.impact(for: .profile(profile.id)))
            }
            .disabled(isPreview)
        }
        .ruleWorkspaceDropTarget(
            model: model,
            target: .profile(profile.id),
            selection: .profile(profile.id),
            pendingDrop: $pendingDrop,
            activeSelection: $activeDropTarget
        )
    }

    private func groupRow(_ group: LocalRuleGroup) -> some View {
        HStack(spacing: 7) {
            Label(display(group.name), systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await model.setGroup(group.id, enabled: !group.isEnabled) }
            } label: {
                Image(systemName: group.isEnabled ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .disabled(isPreview)
            .accessibilityLabel(group.isEnabled
                ? "Disable \(display(group.name))" : "Enable \(display(group.name))")
        }
        .tag(RulesSidebarSelection.group(group.id))
        .contextMenu {
            Button(group.isEnabled ? "Disable" : "Enable") {
                Task { await model.setGroup(group.id, enabled: !group.isEnabled) }
            }
            .disabled(isPreview)
            Button("Edit…") { editor = .group(group) }
                .disabled(isPreview)
            Divider()
            Button("Remove…", role: .destructive) {
                pendingRemoval = .group(group, model.impact(for: .group(group.id)))
            }
            .disabled(isPreview)
        }
        .ruleWorkspaceDropTarget(
            model: model,
            target: .localGroup(group.id),
            selection: .group(group.id),
            pendingDrop: $pendingDrop,
            activeSelection: $activeDropTarget
        )
    }

    private func blocklistRow(_ source: BlocklistSource) -> some View {
        HStack(spacing: 7) {
            Label(display(source.name), systemImage: "list.bullet.rectangle")
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(source.entryCount.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                Task { await model.setBlocklist(source.id, enabled: source.status != .active) }
            } label: {
                Image(systemName: source.status == .active ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            .disabled(isPreview)
            .accessibilityLabel(source.status == .active
                ? "Disable \(display(source.name))" : "Enable \(display(source.name))")
        }
        .tag(RulesSidebarSelection.blocklist(source.id))
        .contextMenu {
            Button(source.status == .active ? "Disable" : "Enable") {
                Task { await model.setBlocklist(source.id, enabled: source.status != .active) }
            }
            .disabled(isPreview)
            Divider()
            Button("Remove…", role: .destructive) {
                pendingRemoval = .blocklist(
                    source,
                    model.impact(for: .blocklist(source.id))
                )
            }
            .disabled(isPreview)
        }
    }

    @ViewBuilder
    private func removalButtons(_ removal: RuleDefinitionRemoval) -> some View {
        switch removal {
        case .profile(let profile, let impact):
            if impact.protectedRules == 0 {
                Button("Detach \(impact.totalRules) Rules and Remove") {
                    Task { await model.removeProfile(profile.id, deletingRules: false) }
                }
                Button("Delete \(impact.totalRules) Rules and Remove", role: .destructive) {
                    Task { await model.removeProfile(profile.id, deletingRules: true) }
                }
            }
        case .group(let group, let impact):
            if impact.protectedRules == 0 {
                Button("Detach \(impact.totalRules) Rules and Remove") {
                    Task { await model.removeGroup(group.id, deletingRules: false) }
                }
                Button("Delete \(impact.totalRules) Rules and Remove", role: .destructive) {
                    Task { await model.removeGroup(group.id, deletingRules: true) }
                }
            }
        case .blocklist(let source, let impact):
            Button("Remove Source and \(impact.totalRules) Managed Rules", role: .destructive) {
                Task { await model.removeBlocklist(source.id) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private var removalTitle: String {
        guard let pendingRemoval else { return "Remove collection?" }
        return "Remove “\(display(pendingRemoval.name))”?"
    }

    private func removalMessage(_ removal: RuleDefinitionRemoval) -> String {
        switch removal {
        case .profile(_, let impact), .group(_, let impact):
            if impact.protectedRules > 0 {
                return "This collection has \(impact.protectedRules) protected or managed rule(s), so it cannot be removed."
            }
            return "Choose whether to detach or delete its \(impact.totalRules) rule(s). Existing connections keep their current decision."
        case .blocklist(let source, let impact):
            return "This removes \(source.entryCount.formatted()) imported entries and \(impact.totalRules) managed rule(s). Existing connections keep their current decision."
        }
    }

    private var policyState: String {
        switch model.enforcementState {
        case .savedPendingEnforcement: "Saved"
        case .persistedPendingProvider: "Persisted"
        case .enforced: "Enforced"
        case .applyFailed: "Apply failed"
        }
    }

    private var policyStateSymbol: String {
        model.enforcementState == .enforced ? "checkmark.shield" : "exclamationmark.shield"
    }

    private func symbol(_ filter: RuleListFilter) -> String {
        switch filter {
        case .all: "list.bullet"
        case .active: "checkmark.circle"
        case .denied: "nosign"
        case .recentlyModified: "clock.arrow.circlepath"
        case .recentlyUsed: "clock.badge.checkmark"
        case .temporary: "timer"
        case .unreviewed: "questionmark.circle"
        }
    }

    private func display(_ value: String) -> String { DisplaySanitizer.plainText(value) }
}

enum RuleDefinitionEditor: Identifiable {
    case newProfile
    case profile(PolicyProfile)
    case newGroup
    case group(LocalRuleGroup)

    var id: String {
        switch self {
        case .newProfile: "new-profile"
        case .profile(let value): "profile-\(value.id.uuidString)"
        case .newGroup: "new-group"
        case .group(let value): "group-\(value.id.uuidString)"
        }
    }
}

private enum RuleDefinitionRemoval: Identifiable {
    case profile(PolicyProfile, RuleDefinitionImpact)
    case group(LocalRuleGroup, RuleDefinitionImpact)
    case blocklist(BlocklistSource, RuleDefinitionImpact)

    var id: String {
        switch self {
        case .profile(let value, _): "profile-\(value.id.uuidString)"
        case .group(let value, _): "group-\(value.id.uuidString)"
        case .blocklist(let value, _): "blocklist-\(value.id.uuidString)"
        }
    }

    var name: String {
        switch self {
        case .profile(let value, _): value.name
        case .group(let value, _): value.name
        case .blocklist(let value, _): value.name
        }
    }
}
