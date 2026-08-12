import RiftControl
import RiftCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controlPlane: ControlPlaneController
    let geolocation: GeolocationController
    let lifecycle: FilterLifecycleController?
    let isPreview: Bool
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notificationSensitiveDetails") private var sensitiveDetails = false
    @AppStorage("statusRecentLimit") private var recentLimit = 10
    @AppStorage("alertDefaultLifetime") private var alertDefaultLifetime = "Once"
    @AppStorage("alertDefaultScope") private var alertDefaultScope = "Current profile"
    @State private var section: SettingsSection = .general
    @State private var launchAtLogin = false
    @State private var baseMode: OperationMode = .silentAllow
    @State private var effectiveMode: OperationMode = .silentAllow
    @State private var confirmedBaseMode: OperationMode = .silentAllow
    @State private var isChangingBaseMode = false
    @State private var historyEnabled = true
    @State private var retentionDays = 30
    @State private var maximumFlows = 50_000
    @State private var message: String?
    @State private var importData: Data?
    @State private var showingRestoreConfirmation = false
    @State private var pendingHistoryExport: HistoryExportFormat?
    @State private var showingDisableHistoryChoice = false
    @State private var showingClearHistoryConfirmation = false
    @State private var restoreNeedsRetry = false
    @State private var groups: [LocalRuleGroup] = []
    @State private var profiles: [PolicyProfile] = []
    @State private var blocklists: [BlocklistSource] = []
    @State private var activeProfileID: UUID?
    @State private var newProfileName = ""
    @State private var newGroupName = ""
    @State private var blocklistName = "Local Blocklist"
    @State private var editingProfile: PolicyProfile?
    @State private var editingGroup: LocalRuleGroup?
    @State private var definitionName = ""
    @State private var definitionNote = ""
    @State private var loaded = false

    var body: some View {
        NavigationSplitView {
            List(availableSections, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 155, ideal: 175)
        } detail: {
            pane
                .navigationTitle(section.rawValue)
                .disabled(isPreview)
                .overlay(alignment: .topTrailing) {
                    if isPreview {
                        Text("Preview")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 600)
        .task {
            guard !isPreview else { return }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            recentLimit = min(max(recentLimit, 0), 25)
            if !["Once", "One hour", "Permanent"].contains(alertDefaultLifetime) {
                alertDefaultLifetime = "Once"
            }
            if !["Current profile", "All profiles"].contains(alertDefaultScope) {
                alertDefaultScope = "Current profile"
            }
            await load()
            loaded = true
        }
        .safeAreaInset(edge: .bottom) {
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar)
            }
        }
        .confirmationDialog(
            "Restore this configuration?",
            isPresented: $showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive, action: restoreConfiguration)
            Button("Cancel", role: .cancel) { importData = nil }
        } message: {
            Text(controlPlane.configurationRecoveryRequired
                ? "The invalid database will be preserved in an owner-only quarantine before recovery."
                : "A backup is created first. Local policy lineage and generation counters are preserved.")
        }
        .confirmationDialog(
            "Export sensitive connection history?",
            isPresented: Binding(
                get: { pendingHistoryExport != nil },
                set: { if !$0 { pendingHistoryExport = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Export", action: exportHistory)
            Button("Cancel", role: .cancel) { pendingHistoryExport = nil }
        } message: {
            Text("The export can contain app identities, destinations, ports, and connection times.")
        }
        .confirmationDialog(
            "Turn off persistent history?",
            isPresented: $showingDisableHistoryChoice,
            titleVisibility: .visible
        ) {
            Button("Turn Off and Keep Existing") { applyHistorySettings(clearHistory: false) }
            Button("Turn Off and Clear History", role: .destructive) {
                applyHistorySettings(clearHistory: true)
            }
            Button("Turn Off and Clear History and Usage", role: .destructive) {
                applyHistorySettings(clearHistory: true, clearUsage: true)
            }
            Button("Cancel", role: .cancel) { historyEnabled = true }
        } message: {
            Text("New connections will not be persisted.")
        }
        .confirmationDialog(
            "Clear connection history?",
            isPresented: $showingClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History Only", role: .destructive) {
                clearHistory(clearUsage: false)
            }
            Button("Clear History and Rule Usage", role: .destructive) {
                clearHistory(clearUsage: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone. Rules and configuration are not deleted.")
        }
        .alert("Rename Profile", isPresented: Binding(
            get: { editingProfile != nil },
            set: { if !$0 { editingProfile = nil } }
        )) {
            TextField("Profile name", text: $definitionName)
            Button("Save", action: saveProfileName)
            Button("Cancel", role: .cancel) { editingProfile = nil }
        }
        .alert("Edit Local Group", isPresented: Binding(
            get: { editingGroup != nil },
            set: { if !$0 { editingGroup = nil } }
        )) {
            TextField("Group name", text: $definitionName)
            TextField("Note", text: $definitionNote)
            Button("Save", action: saveGroup)
            Button("Cancel", role: .cancel) { editingGroup = nil }
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .general:
            GeneralSettingsPane(
                baseMode: $baseMode,
                launchAtLogin: $launchAtLogin,
                effectiveMode: effectiveMode,
                isChangingBaseMode: isChangingBaseMode,
                baseModeChanged: changeBaseMode,
                loginItemChanged: configureLoginItem
            )
        case .alerts:
            AlertSettingsPane(
                notificationsEnabled: $notificationsEnabled,
                sensitiveDetails: $sensitiveDetails,
                alertDefaultLifetime: $alertDefaultLifetime,
                alertDefaultScope: $alertDefaultScope,
                recentLimit: $recentLimit,
                permissionRequested: requestNotificationPermission
            )
        case .history:
            HistorySettingsPane(
                historyEnabled: $historyEnabled,
                retentionDays: $retentionDays,
                maximumFlows: $maximumFlows,
                apply: {
                    if historyEnabled { applyHistorySettings(clearHistory: false) }
                    else { showingDisableHistoryChoice = true }
                },
                clear: { showingClearHistoryConfirmation = true },
                export: { pendingHistoryExport = $0 }
            )
        case .map:
            GeoSettingsPane(geolocation: geolocation)
        case .policies:
            PolicySettingsPane(
                controlPlane: controlPlane,
                groups: $groups,
                profiles: $profiles,
                blocklists: $blocklists,
                activeProfileID: $activeProfileID,
                newProfileName: $newProfileName,
                newGroupName: $newGroupName,
                blocklistName: $blocklistName,
                message: $message,
                editProfile: beginEditing,
                editGroup: beginEditing,
                reload: loadDefinitions
            )
        case .advanced:
            AdvancedSettingsPane(
                controlPlane: controlPlane,
                lifecycle: lifecycle,
                isPreview: isPreview,
                message: $message,
                importData: $importData,
                showingRestoreConfirmation: $showingRestoreConfirmation,
                restoreNeedsRetry: $restoreNeedsRetry
            )
        }
    }

    private var availableSections: [SettingsSection] {
        SettingsSection.allCases.filter {
            $0 != .map || geolocation.isMapUIAdmitted
        }
    }

    private func load() async {
        do {
            let presentation = try await controlPlane.policyPresentation()
            baseMode = presentation.baseMode
            confirmedBaseMode = presentation.baseMode
            effectiveMode = presentation.effectiveMode
            if let settings = try await controlPlane.historySettings() {
                historyEnabled = settings.enabled
                retentionDays = settings.retentionDays
                maximumFlows = settings.maximumFlows
            }
            await loadDefinitions()
        } catch {
            message = "Settings could not be loaded. Retry after Rift reconnects."
        }
    }

    private func loadDefinitions() async {
        do {
            let definitions = try await controlPlane.policyDefinitions()
            groups = definitions.groups
            profiles = definitions.profiles
            activeProfileID = definitions.active
            blocklists = try await controlPlane.blocklistSources()
        } catch {
            message = "Policy definitions could not be loaded."
        }
    }

    private func changeBaseMode(_ value: OperationMode) {
        guard loaded, !isChangingBaseMode else {
            baseMode = confirmedBaseMode
            return
        }
        let previous = confirmedBaseMode
        isChangingBaseMode = true
        Task { @MainActor in
            var failureMessage: String?
            var wasSaved = false
            do {
                let result = try await controlPlane.setBaseMode(value)
                wasSaved = true
                if result.requiresAttention { failureMessage = result.message }
            } catch {
                failureMessage = "The base mode was not saved."
            }
            do {
                let presentation = try await controlPlane.policyPresentation()
                baseMode = presentation.baseMode
                confirmedBaseMode = presentation.baseMode
                effectiveMode = presentation.effectiveMode
            } catch {
                baseMode = wasSaved ? value : previous
                confirmedBaseMode = wasSaved ? value : previous
                failureMessage = failureMessage
                    ?? (wasSaved
                        ? "The base mode was saved, but Settings could not refresh it."
                        : "Settings could not refresh the base mode.")
            }
            message = failureMessage
            isChangingBaseMode = false
        }
    }

    private func applyHistorySettings(clearHistory: Bool, clearUsage: Bool = false) {
        perform("History settings were not changed.") {
            try await controlPlane.configureHistory(
                enabled: historyEnabled,
                retentionDays: retentionDays,
                maximumFlows: maximumFlows
            )
            if clearHistory { try await controlPlane.clearHistory(clearUsage: clearUsage) }
        }
    }

    private func clearHistory(clearUsage: Bool) {
        perform(clearUsage
            ? "Connection history and rule usage were not cleared."
            : "Connection history was not cleared.") {
            try await controlPlane.clearHistory(clearUsage: clearUsage)
        }
    }

    private func requestNotificationPermission(_ enabled: Bool) {
        guard enabled else { return }
        Task {
            do {
                let granted = try await controlPlane.requestNotificationPermission()
                if !granted {
                    notificationsEnabled = false
                    message = "macOS did not grant notification permission."
                }
            } catch {
                notificationsEnabled = false
                message = "Notification permission could not be requested."
            }
        }
    }

    private func restoreConfiguration() {
        guard let importData else { return }
        Task {
            do {
                let outcome = try await controlPlane.restoreConfigurationArchive(importData)
                switch outcome {
                case .enforced:
                    restoreNeedsRetry = false
                    message = "Configuration restored and enforced."
                case .savedPendingEnforcement:
                    restoreNeedsRetry = true
                    message = "The restored configuration is saved but not enforced."
                }
                self.importData = nil
            } catch {
                self.importData = nil
                message = restoreFailureMessage(error)
            }
        }
    }

    private func restoreFailureMessage(_ error: any Error) -> String {
        guard let databaseError = error as? ConfigurationDatabaseError else {
            return "The restore did not save a new configuration. The original configuration remains in place."
        }
        switch databaseError {
        case .unsupportedSchema:
            return "The configuration database was created by a newer Rift version. It was not quarantined or changed. Update Rift before retrying."
        case .recoveryRollbackFailed:
            return "Database recovery did not complete, and the original could not be restored automatically. Inspect the owner-only Configuration Quarantine before retrying."
        case .recoveryPreparationCleanupFailed:
            return "The replacement was not activated and the original remains in place, but the staged recovery database could not be closed cleanly."
        case .schemaPreflightCleanupFailed:
            return "The database was not changed, but Rift could not remove its private schema-check copy. Recovery did not continue."
        case .invalidDatabaseDirectory, .integrityCheckFailed:
            return "The restore did not save a new configuration. The original configuration remains in place."
        }
    }

    private func exportHistory() {
        guard let format = pendingHistoryExport else { return }
        pendingHistoryExport = nil
        perform("The history export was not saved.") {
            let data = try await controlPlane.historyExportData(format: format)
            try await ArchiveFileAccess.save(
                data: data,
                suggestedName: "Rift Connection History.\(format == .json ? "json" : "csv")"
            )
        }
    }

    private func beginEditing(_ profile: PolicyProfile) {
        definitionName = profile.name
        editingProfile = profile
    }

    private func beginEditing(_ group: LocalRuleGroup) {
        definitionName = group.name
        definitionNote = group.note
        editingGroup = group
    }

    private func saveProfileName() {
        guard let profile = editingProfile else { return }
        editingProfile = nil
        performDefinitionMutation("The profile was not renamed.") {
            try await controlPlane.updateProfile(profile.id, name: definitionName)
        }
    }

    private func saveGroup() {
        guard let group = editingGroup else { return }
        editingGroup = nil
        performDefinitionMutation("The group was not updated.") {
            try await controlPlane.updateLocalGroup(
                group.id, name: definitionName, note: definitionNote
            )
        }
    }

    private func performDefinitionMutation(
        _ failureMessage: String,
        operation: @escaping @MainActor () async throws -> ConfigurationMutationResult
    ) {
        Task { @MainActor in
            do {
                let result = try await operation()
                message = result.message
            } catch {
                message = failureMessage
            }
            await loadDefinitions()
        }
    }

    private func perform(
        _ failureMessage: String,
        reloadDefinitions: Bool = false,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor in
            do {
                try await operation()
                message = nil
                if reloadDefinitions { await loadDefinitions() }
            } catch {
                message = ArchiveFileAccess.message(for: error, fallback: failureMessage)
            }
        }
    }

    private func configureLoginItem(_ enabled: Bool) {
        guard loaded else {
            launchAtLogin = false
            message = "Rift is still checking the login-item setting. Try again in a moment."
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = "macOS did not change the login-item setting."
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case alerts = "Alerts"
    case history = "Monitor & Privacy"
    case map = "Map Data"
    case policies = "Policies"
    case advanced = "Advanced"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "gear"
        case .alerts: "bell"
        case .history: "eye.slash"
        case .map: "map"
        case .policies: "switch.2"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}
