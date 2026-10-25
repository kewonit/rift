import RiftControl
import RiftCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let controlPlane: ControlPlaneController
    let lifecycle: FilterLifecycleController?
    let isPreview: Bool
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @AppStorage("notificationSensitiveDetails") private var sensitiveDetails = false
    @AppStorage("statusRecentLimit") private var recentLimit = 5
    @AppStorage("alertDefaultLifetime") private var alertDefaultLifetime = "Once"
    @AppStorage("alertDefaultScope") private var alertDefaultScope = "Current profile"
    @State private var section: SettingsSection = .general
    @State private var launchAtLogin = false
    @State private var loginItemLoaded = false
    @State private var baseMode: OperationMode = .silentAllow
    @State private var effectiveMode: OperationMode = .silentAllow
    @State private var confirmedBaseMode: OperationMode = .silentAllow
    @State private var isChangingBaseMode = false
    @State private var historyEnabled = false
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
        TabView(selection: $section) {
            ForEach(SettingsSection.allCases) { item in
                VStack(spacing: 0) {
                    if isPreview {
                        Label("Preview mode — settings can’t be changed", systemImage: "eye")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                        Divider()
                    }
                    pane(for: item)
                        .allowsHitTesting(!isPreview)
                        .accessibilityHidden(isPreview)
                }
                .tabItem { Label(item.title, systemImage: item.symbol) }
                .tag(item)
            }
        }
        .frame(width: 640, height: 520)
        .task {
            guard !isPreview else {
#if DEBUG
                loadFixtureSettings()
#endif
                loaded = true
                loginItemLoaded = true
                return
            }
            recentLimit = min(max(recentLimit, 0), 25)
            if alertDefaultLifetime == "Permanent" { alertDefaultLifetime = "Always" }
            if !["Once", "One hour", "Always"].contains(alertDefaultLifetime) {
                alertDefaultLifetime = "Once"
            }
            if !["Current profile", "All profiles"].contains(alertDefaultScope) {
                alertDefaultScope = "Current profile"
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemLoaded = true
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
                ? "Rift will keep a private copy of the damaged configuration before restoring."
                : "Rift backs up your current configuration first.")
        }
        .confirmationDialog(
            "Export connection history?",
            isPresented: Binding(
                get: { pendingHistoryExport != nil },
                set: { if !$0 { pendingHistoryExport = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Export", action: exportHistory)
            Button("Cancel", role: .cancel) { pendingHistoryExport = nil }
        } message: {
            Text("The file can include app names, destinations, ports, and connection times. Share it with care.")
        }
        .confirmationDialog(
            "Turn off connection history?",
            isPresented: $showingDisableHistoryChoice,
            titleVisibility: .visible
        ) {
            Button("Turn Off and Keep History") { applyHistorySettings(clearHistory: false) }
            Button("Turn Off and Clear History", role: .destructive) {
                applyHistorySettings(clearHistory: true)
            }
            Button("Turn Off and Clear History and Rule Usage", role: .destructive) {
                applyHistorySettings(clearHistory: true, clearUsage: true)
            }
            Button("Cancel", role: .cancel) { historyEnabled = true }
        } message: {
            Text("Rift will stop saving new connections.")
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
            Text("This can’t be undone. Your rules and settings aren’t affected.")
        }
        .alert("Rename Profile", isPresented: Binding(
            get: { editingProfile != nil },
            set: { if !$0 { editingProfile = nil } }
        )) {
            TextField("Profile name", text: $definitionName)
            Button("Save", action: saveProfileName)
            Button("Cancel", role: .cancel) { editingProfile = nil }
        }
        .alert("Edit Group", isPresented: Binding(
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
    private func pane(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsPane(
                baseMode: $baseMode,
                launchAtLogin: $launchAtLogin,
                effectiveMode: effectiveMode,
                isChangingBaseMode: isChangingBaseMode || !loaded,
                isLoginItemReady: loginItemLoaded,
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

#if DEBUG
    private func loadFixtureSettings() {
        let configuration = MonitorFixtureData.ruleWorkspaceSnapshot.configuration
        baseMode = configuration.baseOperationMode
        confirmedBaseMode = configuration.baseOperationMode
        effectiveMode = configuration.operationMode
        groups = configuration.localGroups
        profiles = configuration.profiles
        blocklists = configuration.blocklists
        activeProfileID = configuration.activeProfileID
    }
#endif

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
            message = "Couldn’t load settings. Try again in a moment."
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
            message = "Couldn’t load profiles, groups, and blocklists."
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
                failureMessage = "Couldn’t change the default mode. Try again."
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
                        ? "The default mode was saved, but Settings couldn’t show the update."
                        : "Couldn’t refresh the default mode.")
            }
            message = failureMessage
            isChangingBaseMode = false
        }
    }

    private func applyHistorySettings(clearHistory: Bool, clearUsage: Bool = false) {
        perform("Couldn’t change history settings. Try again.") {
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
            ? "Couldn’t clear connection history and rule usage."
            : "Couldn’t clear connection history.") {
            try await controlPlane.clearHistory(clearUsage: clearUsage)
        }
    }

    private func requestNotificationPermission(_ enabled: Bool) {
        controlPlane.requestActivitySubscriptionUpdate()
        guard enabled else { return }
        Task {
            do {
                let granted = try await controlPlane.requestNotificationPermission()
                if !granted {
                    notificationsEnabled = false
                    message = "Notifications aren’t allowed. Turn them on in System Settings › Notifications."
                }
            } catch {
                notificationsEnabled = false
                message = "Rift couldn’t ask for notification permission. Try again."
            }
            controlPlane.requestActivitySubscriptionUpdate()
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
                    message = "Configuration restored and active."
                case .savedPendingEnforcement:
                    restoreNeedsRetry = true
                    message = "The restored configuration is saved, but the filter isn’t using it yet."
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
            return "Nothing was restored. Your current configuration hasn’t changed."
        }
        switch databaseError {
        case .unsupportedSchema:
            return "This configuration was saved by a newer version of Rift, so Rift left it unchanged. Update Rift, then try again."
        case .recoveryRollbackFailed:
            return "Recovery didn’t finish, and Rift couldn’t put the original configuration back. A private copy is in the Configuration Quarantine folder. Check it before you try again."
        case .recoveryPreparationCleanupFailed:
            return "Nothing was restored, and your current configuration hasn’t changed. Rift couldn’t clean up a temporary file."
        case .schemaPreflightCleanupFailed:
            return "Recovery stopped. Your configuration hasn’t changed, but Rift couldn’t remove a temporary copy."
        case .invalidDatabaseDirectory, .integrityCheckFailed:
            return "Nothing was restored. Your current configuration hasn’t changed."
        }
    }

    private func exportHistory() {
        guard let format = pendingHistoryExport else { return }
        pendingHistoryExport = nil
        perform("Couldn’t export connection history.") {
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
        performDefinitionMutation("Couldn’t rename the profile.") {
            try await controlPlane.updateProfile(profile.id, name: definitionName)
        }
    }

    private func saveGroup() {
        guard let group = editingGroup else { return }
        editingGroup = nil
        performDefinitionMutation("Couldn’t update the group.") {
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
        guard loginItemLoaded else {
            launchAtLogin = false
            message = "Rift is still checking whether it opens at login. Try again in a moment."
            return
        }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = "macOS couldn’t change whether Rift opens at login. Check Login Items in System Settings."
        }
    }
}
