import RiftControl
import RiftCore
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

/// One row of the app sidebar.
enum AppSidebarItem: Hashable {
    case map
    case status
    case rules(RulesSidebarSelection)
}

/// The app sidebar: the pages, then rules and what they're organized into.
struct RiftSidebarView: View {
    @Bindable var model: RulesWorkspaceController
    @Binding var selection: AppSidebarItem
    let isPreview: Bool
    @State private var editor: RuleDefinitionEditor?
    @State private var pendingRemoval: RuleDefinitionRemoval?
    @State private var pendingDrop: RuleWorkspaceDropRequest?
    @State private var activeDropTarget: RulesSidebarSelection?
    @State private var showingBlocklistImport = false

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .selectionDisabled()
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label(AppDestination.liveMap.title, systemImage: "map").tag(AppSidebarItem.map)
                Label(AppDestination.health.title, systemImage: "shield").tag(AppSidebarItem.status)
            }
            .listItemTint(.monochrome)
            Section("Rules") {
                ForEach(RuleListFilter.allCases) { filter in
                    Label(filter.rawValue, systemImage: symbol(filter))
                        .tag(AppSidebarItem.rules(.filter(filter)))
                }
            }
            .listItemTint(.monochrome)
            // These sections wait for the first load. Filling them while the
            // sidebar does its first layout made AppKit warn about reentrancy.
            if model.hasLoaded {
                Section("Profiles") {
                    ForEach(model.profiles) { profile in profileRow(profile) }
                    if model.profiles.isEmpty {
                        emptyHint("Rule sets, like Home and Work.")
                    }
                }
                .listItemTint(.monochrome)
                Section("Groups") {
                    ForEach(model.groups) { group in groupRow(group) }
                    if model.groups.isEmpty {
                        emptyHint("Turn rules on and off together.")
                    }
                }
                .listItemTint(.monochrome)
                Section("Blocklists") {
                    ForEach(model.blocklists) { source in blocklistRow(source) }
                    if model.blocklists.isEmpty {
                        emptyHint("Block many sites from a file.")
                    }
                }
                .listItemTint(.monochrome)
            }
        }
        .listStyle(.sidebar)
        .task { await model.reload() }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Menu {
                    Button("New Profile…") { editor = .newProfile }
                    Button("New Group…") { editor = .newGroup }
                    Divider()
                    Button("Import Blocklist…") { showingBlocklistImport = true }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isPreview)
                Spacer()
                Label(policyState, systemImage: policyStateSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Whether the filter is using your latest rules")
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

    private func rowCheckbox(isOn: Bool, label: String, set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { isOn }, set: set))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(isPreview)
    }

    private func profileRow(_ profile: PolicyProfile) -> some View {
        HStack(spacing: 7) {
            Label(display(profile.name), systemImage: "person")
                .lineLimit(1)
            Spacer(minLength: 4)
            rowCheckbox(
                isOn: model.activeProfileID == profile.id,
                label: model.activeProfileID == profile.id
                    ? "Deactivate \(display(profile.name))" : "Activate \(display(profile.name))"
            ) { on in
                Task { await model.activateProfile(on ? profile.id : nil) }
            }
        }
        .tag(AppSidebarItem.rules(.profile(profile.id)))
        .contextMenu {
            Button(model.activeProfileID == profile.id ? "Deactivate" : "Activate") {
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
            rowCheckbox(
                isOn: group.isEnabled,
                label: group.isEnabled ? "Disable \(display(group.name))" : "Enable \(display(group.name))"
            ) { on in
                Task { await model.setGroup(group.id, enabled: on) }
            }
        }
        .tag(AppSidebarItem.rules(.group(group.id)))
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
            Label(display(source.name), systemImage: "doc.text")
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(source.entryCount.formatted())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            rowCheckbox(
                isOn: source.status == .active,
                label: source.status == .active ? "Disable \(display(source.name))" : "Enable \(display(source.name))"
            ) { on in
                Task { await model.setBlocklist(source.id, enabled: on) }
            }
        }
        .tag(AppSidebarItem.rules(.blocklist(source.id)))
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
                Button("Remove and Keep \(ruleCount(impact.totalRules, title: true))") {
                    Task { await model.removeProfile(profile.id, deletingRules: false) }
                }
                Button("Remove and Delete \(ruleCount(impact.totalRules, title: true))", role: .destructive) {
                    Task { await model.removeProfile(profile.id, deletingRules: true) }
                }
            }
        case .group(let group, let impact):
            if impact.protectedRules == 0 {
                Button("Remove and Keep \(ruleCount(impact.totalRules, title: true))") {
                    Task { await model.removeGroup(group.id, deletingRules: false) }
                }
                Button("Remove and Delete \(ruleCount(impact.totalRules, title: true))", role: .destructive) {
                    Task { await model.removeGroup(group.id, deletingRules: true) }
                }
            }
        case .blocklist(let source, let impact):
            Button("Remove Blocklist and \(ruleCount(impact.totalRules, title: true))", role: .destructive) {
                Task { await model.removeBlocklist(source.id) }
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private var removalTitle: String {
        guard let pendingRemoval else { return "Remove this item?" }
        return "Remove “\(display(pendingRemoval.name))”?"
    }

    private func removalMessage(_ removal: RuleDefinitionRemoval) -> String {
        switch removal {
        case .profile(_, let impact), .group(_, let impact):
            if impact.protectedRules > 0 {
                let locked = impact.protectedRules == 1
                    ? "1 rule that’s protected or comes from a blocklist"
                    : "\(impact.protectedRules) rules that are protected or come from a blocklist"
                return "This can’t be removed because it contains \(locked)."
            }
            let kept: String
            if case .profile = removal {
                kept = "Kept rules will apply to all profiles."
            } else {
                kept = "Kept rules won’t belong to any group."
            }
            return "Choose whether to keep or delete its \(ruleCount(impact.totalRules)). \(kept) Open connections aren’t affected."
        case .blocklist(let source, let impact):
            let entries = source.entryCount == 1 ? "1 entry" : "\(source.entryCount.formatted()) entries"
            return "This removes \(entries) and \(ruleCount(impact.totalRules)) from this blocklist. Open connections aren’t affected."
        }
    }

    private var policyState: String {
        switch model.enforcementState {
        case .savedPendingEnforcement: "Rules pending"
        case .persistedPendingProvider: "Rules pending"
        case .enforced: "Rules active"
        case .applyFailed: "Rules not applied"
        }
    }

    private var policyStateSymbol: String {
        model.enforcementState == .enforced ? "checkmark.shield" : "exclamationmark.shield"
    }

    private func symbol(_ filter: RuleListFilter) -> String {
        switch filter {
        case .all: "list.bullet"
        case .active: "checkmark"
        case .denied: "hand.raised"
        case .recentlyModified: "pencil"
        case .recentlyUsed: "clock"
        case .temporary: "hourglass"
        case .unreviewed: "tray"
        }
    }

    private func display(_ value: String) -> String { DisplaySanitizer.plainText(value) }

    private func ruleCount(_ count: Int, title: Bool = false) -> String {
        let noun = title ? (count == 1 ? "Rule" : "Rules") : (count == 1 ? "rule" : "rules")
        return "\(count) \(noun)"
    }
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
