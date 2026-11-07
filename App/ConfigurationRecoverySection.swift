import RiftControl
import SwiftUI

/// The way back when Rift can't read its rules: restore a backup, import a
/// file, or start fresh.
struct ConfigurationRecoverySection: View {
    @Bindable var session: AppSession
    @Environment(\.openSettings) private var openSettings
    @State private var backupDay: String?
    @State private var checked = false
    @State private var restoring = false
    @State private var showingConfirmation = false

    private var controller: ControlPlaneController { session.controlPlane }

    var body: some View {
        Section("Get Your Rules Back") {
            VStack(alignment: .leading, spacing: RiftDesign.Spacing.xs) {
                if let backupDay {
                    Text("Rift has a working backup from \(backupDay).")
                } else if checked {
                    Text("Rift couldn’t find a backup it can read.")
                }
                Text("Rift keeps a private copy of the damaged configuration whichever you choose.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if backupDay != nil {
                    Button("Restore Backup…") { showingConfirmation = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(restoring)
                }
                Button("Import a File…", action: openAdvancedSettings)
                Spacer()
                Button("Start Fresh…", action: openAdvancedSettings)
            }
        }
        .task {
            backupDay = await controller.latestBackupDay()
            checked = true
        }
        .confirmationDialog(
            "Restore the backup from \(backupDay ?? "")?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore Backup", action: restore)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rules you changed after this backup won’t come back.")
        }
    }

    private func openAdvancedSettings() {
        UserDefaults.standard.set(SettingsSection.advanced.rawValue, forKey: "settingsSection")
        openSettings()
    }

    private func restore() {
        restoring = true
        Task { @MainActor in
            defer { restoring = false }
            do {
                _ = try await controller.restoreLatestBackup()
                controller.actionResults.post("Your rules are back, from the backup on \(backupDay ?? "that day").")
            } catch {
                controller.actionResults.post(
                    "Rift couldn’t restore that backup. Try importing a file instead.",
                    tone: .failure
                )
            }
        }
    }
}
