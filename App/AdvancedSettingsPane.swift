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
                    Button("Retry Applying Restored Configuration", action: retryRestore)
                    Button("Roll Back Restored Configuration", role: .destructive, action: rollbackRestore)
                        .disabled(!controlPlane.canRollbackLastRestore)
                }
            }
            Section {
                DisclosureGroup("Bundle Contents") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(diagnosticsPreview?.defaultSections ?? [], id: \.self) {
                            Label($0, systemImage: "checkmark.shield")
                        }
                        Toggle("Pseudonymized recent visible activity", isOn: option(.recentActivity))
                        Toggle("Pseudonymized rule summaries", isOn: option(.ruleSummaries))
                        Toggle("Current-process log excerpts", isOn: option(.appLogExcerpts))
                        ForEach(diagnosticsPreview?.optionalSections ?? [], id: \.self) {
                            Label($0, systemImage: "exclamationmark.lock")
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.top, 6)
                }
                Button("Save Diagnostics Bundle…", action: saveDiagnostics)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Optional values are freshly pseudonymized for each bundle and are never uploaded automatically.")
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
            "Uninstall the Abyss network filter?",
            isPresented: $showingUninstallConfirmation,
            titleVisibility: .visible
        ) {
            Button("Uninstall Network Filter", role: .destructive, action: uninstall)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Abyss will first verify fail-open policy cleanup, then ask macOS to remove the filter extension.")
        }
        .alert(
            "Reset the invalid configuration?",
            isPresented: $showingResetConfirmation
        ) {
            TextField("Type RESET", text: $resetConfirmation)
            Button("Reset Configuration", role: .destructive, action: resetConfiguration)
                .disabled(resetConfirmation != "RESET")
            Button("Cancel", role: .cancel) { resetConfirmation = "" }
        } message: {
            Text("This removes editable rules, profiles, groups, and blocklists. The invalid database is preserved in an owner-only quarantine. Filtering stays fail-open until a new empty Silent Allow policy is durably verified.")
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
        perform("The configuration export was not saved.") {
            let data = try await controlPlane.configurationArchiveData()
            try await ArchiveFileAccess.save(
                data: data, suggestedName: "Abyss Configuration.json"
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
                    fallback: "The selected configuration archive could not be validated."
                )
            }
        }
    }

    private func saveDiagnostics() {
        perform("The diagnostics export was not saved.") {
            let data = try await controlPlane.diagnosticsBundleData(options: diagnosticsOptions)
            try await ArchiveFileAccess.save(
                data: data, suggestedName: "Abyss Diagnostics.json"
            )
        }
    }

    private func retryRestore() {
        Task {
            do {
                let outcome = try await controlPlane.retryPendingConfiguration()
                restoreNeedsRetry = outcome == .savedPendingEnforcement
                message = outcome == .enforced
                    ? "The restored configuration is enforced."
                    : "The restored configuration remains saved but is not enforced."
            } catch {
                message = "The restored configuration remains saved but is not enforced."
            }
        }
    }

    private func rollbackRestore() {
        Task {
            do {
                let outcome = try await controlPlane.rollbackLastRestore()
                restoreNeedsRetry = outcome == .savedPendingEnforcement
                message = outcome == .enforced
                    ? "The pre-restore configuration was restored and enforced."
                    : "The pre-restore configuration is saved but not enforced."
            } catch {
                message = "The pre-restore configuration was not saved. The current configuration was not changed."
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
                message = "Fail-open preparation could not be verified. The extension was not removed."
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
                    ? "A fresh empty configuration is enforced in Silent Allow mode."
                    : "A fresh empty configuration is saved. Filtering remains fail-open until enforcement reconnects."
            } catch {
                message = "The configuration was not reset. If root cleanup had already started, filtering remains fail-open; retry from the policy-owner account."
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
