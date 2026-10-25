import SwiftUI

struct AdvancedSettingsPane: View {
    let controlPlane: ControlPlaneController
    let lifecycle: FilterLifecycleController?
    let isPreview: Bool
    @Binding var message: String?
    @Binding var importData: Data?
    @Binding var showingRestoreConfirmation: Bool
    @Binding var restoreNeedsRetry: Bool
    @State private var diagnosticsOptions: DiagnosticsExportOptions = []
    @State private var diagnosticsPreview: DiagnosticsBundlePreview?
    @State private var showingUninstallConfirmation = false
    @State private var preparingUninstall = false
    @State private var showingResetConfirmation = false
    @State private var resetConfirmation = ""
    @State private var resettingConfiguration = false

    var body: some View {
        Form {
            Section("Configuration") {
                Button("Export Configuration…", action: exportConfiguration)
                Button("Import Configuration…", action: importConfiguration)
                if controlPlane.configurationRecoveryRequired {
                    Button("Reset Configuration…", role: .destructive) {
                        resetConfirmation = ""
                        showingResetConfirmation = true
                    }
                    .disabled(resettingConfiguration || isPreview)
                }
                if restoreNeedsRetry || controlPlane.canRollbackLastRestore {
                    Button("Apply Restored Configuration Again", action: retryRestore)
                    Button("Undo Restore", role: .destructive, action: rollbackRestore)
                        .disabled(!controlPlane.canRollbackLastRestore)
                }
            }
            Section {
                DisclosureGroup("What’s Included") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(diagnosticsPreview?.defaultSections ?? [], id: \.self) {
                            Label($0, systemImage: "checkmark.shield")
                        }
                        Toggle("Recent activity (masked)", isOn: option(.recentActivity))
                        Toggle("Rule summaries (masked)", isOn: option(.ruleSummaries))
                        Toggle("Recent Rift log entries", isOn: option(.appLogExcerpts))
                        ForEach(diagnosticsPreview?.optionalSections ?? [], id: \.self) {
                            Label($0, systemImage: "exclamationmark.lock")
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 6)
                }
                Button("Save Diagnostics…", action: saveDiagnostics)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Optional items are masked differently each time you save. Rift never uploads diagnostics.")
            }
            if lifecycle != nil {
                Section("Network Filter") {
                    Button("Uninstall Network Filter…", role: .destructive) {
                        showingUninstallConfirmation = true
                    }
                    .disabled(preparingUninstall || isPreview)
                }
            }
        }
        .formStyle(.grouped)
        .task { await updateDiagnosticsPreview() }
        .onChange(of: diagnosticsOptions) { _, _ in
            Task { await updateDiagnosticsPreview() }
        }
        .confirmationDialog(
            "Uninstall the Rift network filter?",
            isPresented: $showingUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("Uninstall Network Filter", role: .destructive, action: uninstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rift will first make sure all traffic is allowed, then ask macOS to remove the filter.")
        }
        .alert(
            "Reset the damaged configuration?",
            isPresented: $showingResetConfirmation
        ) {
            TextField("Type RESET", text: $resetConfirmation)
            Button("Reset Configuration", role: .destructive, action: resetConfiguration)
                .disabled(resetConfirmation != "RESET")
            Button("Cancel", role: .cancel) { resetConfirmation = "" }
        } message: {
            Text("This deletes your rules, profiles, groups, and blocklists, and starts fresh in Silent Allow mode. Rift keeps a private copy of the damaged configuration. All traffic is allowed until the reset finishes.")
        }
    }

    private func option(_ value: DiagnosticsExportOptions) -> Binding<Bool> {
        Binding(
            get: { diagnosticsOptions.contains(value) },
            set: { enabled in
                if enabled { diagnosticsOptions.insert(value) }
                else { diagnosticsOptions.remove(value) }
            }
        )
    }

    private func exportConfiguration() {
        perform("Couldn’t export the configuration.") {
            let data = try await controlPlane.configurationArchiveData()
            try await ArchiveFileAccess.save(
                data: data, suggestedName: "Rift Configuration.json"
            )
        }
    }

    private func importConfiguration() {
        Task {
            do {
                guard let data = try await ArchiveFileAccess.open() else { return }
                importData = data
                message = try await controlPlane.previewConfigurationArchive(data)
                showingRestoreConfirmation = true
            } catch {
                importData = nil
                message = ArchiveFileAccess.message(
                    for: error,
                    fallback: "Rift couldn’t read this file. Choose a configuration file exported from Rift."
                )
            }
        }
    }

    private func saveDiagnostics() {
        perform("Couldn’t save diagnostics.") {
            let data = try await controlPlane.diagnosticsBundleData(options: diagnosticsOptions)
            try await ArchiveFileAccess.save(
                data: data, suggestedName: "Rift Diagnostics.json"
            )
        }
    }

    private func retryRestore() {
        Task {
            do {
                let outcome = try await controlPlane.retryPendingConfiguration()
                restoreNeedsRetry = outcome == .savedPendingEnforcement
                message = outcome == .enforced
                    ? "The restored configuration is now active."
                    : "The restored configuration is saved, but the filter isn’t using it yet."
            } catch {
                message = "The restored configuration is saved, but the filter isn’t using it yet."
            }
        }
    }

    private func rollbackRestore() {
        Task {
            do {
                let outcome = try await controlPlane.rollbackLastRestore()
                restoreNeedsRetry = outcome == .savedPendingEnforcement
                message = outcome == .enforced
                    ? "Your previous configuration is back and active."
                    : "Your previous configuration is back, but the filter isn’t using it yet."
            } catch {
                message = "Couldn’t undo the restore. Your current configuration hasn’t changed."
            }
        }
    }

    private func uninstall() {
        guard let lifecycle, !isPreview else { return }
        preparingUninstall = true
        Task {
            let prepared = await controlPlane.prepareForUninstall()
            preparingUninstall = false
            guard prepared else {
                message = "Rift couldn’t confirm that all traffic is allowed, so the filter wasn’t removed. Try again."
                return
            }
            lifecycle.uninstall()
        }
    }

    private func resetConfiguration() {
        guard !isPreview, resetConfirmation == "RESET" else { return }
        resettingConfiguration = true
        resetConfirmation = ""
        Task {
            do {
                let outcome = try await controlPlane.resetConfiguration()
                message = outcome == .enforced
                    ? "Configuration reset. Rift is starting fresh in Silent Allow mode."
                    : "Configuration reset. All traffic is allowed until the filter reconnects."
            } catch {
                message = "The configuration wasn’t reset, and all traffic may be allowed for now. Try again while signed in to the Mac account that manages Rift."
            }
            resettingConfiguration = false
        }
    }

    private func updateDiagnosticsPreview() async {
        diagnosticsPreview = try? await controlPlane.diagnosticsPreview(
            options: diagnosticsOptions
        )
    }

    private func perform(
        _ failureMessage: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor in
            do { try await operation() }
            catch { message = ArchiveFileAccess.message(for: error, fallback: failureMessage) }
        }
    }
}
