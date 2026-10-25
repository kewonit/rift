import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

struct PolicySettingsPane: View {
    let controlPlane: ControlPlaneController
    @Binding var groups: [LocalRuleGroup]
    @Binding var profiles: [PolicyProfile]
    @Binding var blocklists: [BlocklistSource]
    @Binding var activeProfileID: UUID?
    @Binding var newProfileName: String
    @Binding var newGroupName: String
    @Binding var blocklistName: String
    @Binding var message: String?
    let editProfile: (PolicyProfile) -> Void
    let editGroup: (LocalRuleGroup) -> Void
    let reload: @MainActor () async -> Void
    @State private var blocklistEntry = ""
    @State private var entryImpact: BlocklistEntryImpact?
    @State private var pendingDisableImpact: BlocklistEntryImpact?
    @State private var showingDisableConfirmation = false

    var body: some View {
        Form {
            profilesSection
            groupsSection
            blocklistsSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Disable this entry across blocklists?",
            isPresented: $showingDisableConfirmation,
            presenting: pendingDisableImpact
        ) { impact in
            Button("Disable \(impact.entry.description)", role: .destructive) {
                setEntryOverride(impact, disabled: true)
            }
        } message: { impact in
            Text(entryImpactSummary(impact))
        }
    }

    private var profilesSection: some View {
        Section("Profiles") {
            Picker("Active profile", selection: Binding(
                get: { activeProfileID },
                set: { value in
                    activeProfileID = value
                    perform("The active profile was not changed.") {
                        try await controlPlane.activateProfile(value)
                    }
                }
            )) {
                Text("None").tag(UUID?.none)
                ForEach(profiles) { Text($0.name).tag(Optional($0.id)) }
            }
            ForEach(profiles) { profile in
                LabeledContent(profile.name) {
                    Menu("Actions") {
                        Menu("Mode") {
                            modeButtons(profile)
                        }
                        Button("Rename…") { editProfile(profile) }
                        Divider()
                        Button("Remove and Detach Rules") {
                            removeProfile(profile, deletingRules: false)
                        }
                        Button("Remove and Delete Rules", role: .destructive) {
                            removeProfile(profile, deletingRules: true)
                        }
                    }
                }
            }
            HStack {
                TextField("New profile", text: $newProfileName)
                Button("Add", action: addProfile)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var groupsSection: some View {
        Section("Local Rule Groups") {
            ForEach(groups) { group in
                HStack {
                    Toggle(group.name, isOn: Binding(
                        get: { group.isEnabled },
                        set: { setGroup(group, enabled: $0) }
                    ))
                    Button("Edit…") { editGroup(group) }
                    Menu("Remove") {
                        Button("Detach Rules") { removeGroup(group, deletingRules: false) }
                        Button("Delete Group Rules", role: .destructive) {
                            removeGroup(group, deletingRules: true)
                        }
                    }
                }
            }
            HStack {
                TextField("New group", text: $newGroupName)
                Button("Add", action: addGroup)
                    .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var blocklistsSection: some View {
        Section("Local Deny Blocklists") {
            ForEach(blocklists) { source in
                HStack {
                    Toggle(source.name, isOn: Binding(
                        get: { source.status == .active },
                        set: { setBlocklist(source, enabled: $0) }
                    ))
                    Spacer()
                    Text("\(source.entryCount.formatted()) entries")
                        .foregroundStyle(.secondary)
                    Button("Remove", role: .destructive) { removeBlocklist(source) }
                }
            }
            TextField("Imported source name", text: $blocklistName)
            Button("Import Local Blocklist…", action: importBlocklist)
                .disabled(blocklistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Divider()
            TextField("Exact domain, IP, CIDR, or range", text: $blocklistEntry)
                .onChange(of: blocklistEntry) { _, _ in entryImpact = nil }
            HStack {
                Button("Check Entry", action: inspectBlocklistEntry)
                    .disabled(blocklistEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let entryImpact {
                    Spacer()
                    if entryImpact.isDisabled {
                        Button("Re-enable") { setEntryOverride(entryImpact, disabled: false) }
                    } else {
                        Button("Disable Across Lists…") {
                            pendingDisableImpact = entryImpact
                            showingDisableConfirmation = true
                        }
                    }
                }
            }
            if let entryImpact {
                Text(entryImpactSummary(entryImpact))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func modeButtons(_ profile: PolicyProfile) -> some View {
        Button("Use Base Mode") { updateProfileMode(profile, mode: nil) }
        Button("Alert") { updateProfileMode(profile, mode: .alert) }
        Button("Silent Allow") { updateProfileMode(profile, mode: .silentAllow) }
        Button("Silent Deny") { updateProfileMode(profile, mode: .silentDeny) }
        Button("Observe Only") { updateProfileMode(profile, mode: .filterOff) }
    }

    private func addProfile() {
        let name = newProfileName
        newProfileName = ""
        perform("The profile was not created.") { try await controlPlane.createProfile(name: name) }
    }

    private func removeProfile(_ profile: PolicyProfile, deletingRules: Bool) {
        perform("The profile was not removed. Protected or managed rules were preserved.") {
            try await controlPlane.removeProfile(profile.id, deletingRules: deletingRules)
        }
    }

    private func updateProfileMode(_ profile: PolicyProfile, mode: OperationMode?) {
        perform("The profile mode was not changed.") {
            try await controlPlane.updateProfile(profile.id, operationModeOverride: .some(mode))
        }
    }

    private func addGroup() {
        let name = newGroupName
        newGroupName = ""
        perform("The group was not created.") { try await controlPlane.createLocalGroup(name: name) }
    }

    private func setGroup(_ group: LocalRuleGroup, enabled: Bool) {
        perform("The group state was not changed.") {
            try await controlPlane.setLocalGroup(group.id, enabled: enabled)
        }
    }

    private func removeGroup(_ group: LocalRuleGroup, deletingRules: Bool) {
        perform("The group was not removed. Protected or managed rules were preserved.") {
            try await controlPlane.removeLocalGroup(group.id, deletingRules: deletingRules)
        }
    }

    private func setBlocklist(_ source: BlocklistSource, enabled: Bool) {
        perform("The blocklist state was not changed.") {
            try await controlPlane.setBlocklist(source.id, enabled: enabled)
        }
    }

    private func removeBlocklist(_ source: BlocklistSource) {
        perform("The blocklist was not removed.") { try await controlPlane.removeBlocklist(source.id) }
    }

    private func importBlocklist() {
        Task {
            do {
                guard let data = try await ArchiveFileAccess.open(
                    maximumBytes: BlocklistParser.maximumBytes
                ) else { return }
                let result = try await controlPlane.importBlocklist(
                    data: data,
                    name: blocklistName
                )
                message = result.message
                await reload()
            } catch {
                message = "The blocklist was rejected; the active policy was not changed."
                await reload()
            }
        }
    }

    private func inspectBlocklistEntry() {
        Task { @MainActor in
            do {
                entryImpact = try await controlPlane.blocklistEntryImpact(blocklistEntry)
            } catch {
                entryImpact = nil
                message = "That exact entry is not supplied by an imported blocklist."
            }
        }
    }

    private func setEntryOverride(_ impact: BlocklistEntryImpact, disabled: Bool) {
        Task { @MainActor in
            do {
                let result = try await controlPlane.setBlocklistEntryOverride(
                    impact.entry, disabled: disabled
                )
                message = result.message
                await reload()
                entryImpact = try await controlPlane.blocklistEntryImpact(blocklistEntry)
            } catch {
                message = "The blocklist entry state was not changed."
                await reload()
            }
        }
    }

    private func entryImpactSummary(_ impact: BlocklistEntryImpact) -> String {
        let state = impact.isDisabled ? "Disabled" : "Enabled"
        let activeCount = impact.activeSourceNames.count
        let totalCount = impact.sourceNames.count
        let shownNames = impact.sourceNames.prefix(3).joined(separator: ", ")
        let remaining = max(0, totalCount - 3)
        let suffix = remaining == 0 ? shownNames : "\(shownNames) +\(remaining)"
        return "\(state) • \(activeCount) active of \(totalCount) • \(suffix)"
    }

    private func perform(
        _ failureMessage: String,
        operation: @escaping @MainActor () async throws -> ConfigurationMutationResult
    ) {
        Task { @MainActor in
            do {
                let result = try await operation()
                message = result.message
                await reload()
            } catch {
                message = failureMessage
                await reload()
            }
        }
    }
}
