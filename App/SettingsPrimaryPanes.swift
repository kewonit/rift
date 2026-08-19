import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

struct GeneralSettingsPane: View {
    @Binding var baseMode: OperationMode
    @Binding var launchAtLogin: Bool
    let effectiveMode: OperationMode
    let isChangingBaseMode: Bool
    let isLoginItemReady: Bool
    let baseModeChanged: (OperationMode) -> Void
    let loginItemChanged: (Bool) -> Void

    var body: some View {
        Form {
            Section {
                Picker("Base mode", selection: Binding(
                    get: { baseMode },
                    set: { value in
                        baseMode = value
                        baseModeChanged(value)
                    }
                )) {
                    Text("Alert").tag(OperationMode.alert)
                    Text("Silent Allow").tag(OperationMode.silentAllow)
                    Text("Silent Deny").tag(OperationMode.silentDeny)
                    Text("Observe Only").tag(OperationMode.filterOff)
                }
                .disabled(isChangingBaseMode)
                LabeledContent("Effective mode", value: label(effectiveMode))
            } header: {
                Text("Filtering")
            } footer: {
                Text("Observe Only leaves the provider running but allows visible connections.")
            }
            Section("Startup") {
                Toggle("Launch Rift at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { value in
                        launchAtLogin = value
                        loginItemChanged(value)
                    }
                ))
                .disabled(!isLoginItemReady)
            }
        }
        .formStyle(.grouped)
    }

    private func label(_ mode: OperationMode) -> String {
        switch mode {
        case .alert: "Alert"
        case .silentAllow: "Silent Allow"
        case .silentDeny: "Silent Deny"
        case .filterOff: "Observe Only"
        case .degradedFallback: "Degraded Fallback"
        }
    }
}

struct AlertSettingsPane: View {
    @Binding var notificationsEnabled: Bool
    @Binding var sensitiveDetails: Bool
    @Binding var alertDefaultLifetime: String
    @Binding var alertDefaultScope: String
    @Binding var recentLimit: Int
    let permissionRequested: (Bool) -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Connection notifications", isOn: $notificationsEnabled)
                    .onChange(of: notificationsEnabled) { _, value in
                        permissionRequested(value)
                    }
                Toggle("Show destination details", isOn: $sensitiveDetails)
            } header: {
                Text("Notifications")
            } footer: {
                Text("Destination details can appear on the lock screen. Notification actions do not change filtering.")
            }
            Section {
                Picker("Remember decisions", selection: $alertDefaultLifetime) {
                    Text("Once").tag("Once")
                    Text("One hour").tag("One hour")
                    Text("Permanent").tag("Permanent")
                }
                Picker("Rule scope", selection: $alertDefaultScope) {
                    Text("Current profile").tag("Current profile")
                    Text("All profiles").tag("All profiles")
                }
                Stepper("Recent menu items: \(recentLimit)", value: $recentLimit, in: 0...25)
            } header: {
                Text("Defaults")
            } footer: {
                Text("Unanswered alerts use the fixed safety fallback before a flow deadline.")
            }
        }
        .formStyle(.grouped)
    }
}

struct HistorySettingsPane: View {
    @Binding var historyEnabled: Bool
    @Binding var retentionDays: Int
    @Binding var maximumFlows: Int
    let apply: () -> Void
    let clear: () -> Void
    let export: (HistoryExportFormat) -> Void

    var body: some View {
        Form {
            Section("History") {
                Toggle("Persist connection history", isOn: $historyEnabled)
                Stepper("Retention: \(retentionDays) days", value: $retentionDays, in: 1...30)
                Stepper(
                    "Maximum events: \(maximumFlows.formatted())",
                    value: $maximumFlows,
                    in: 1_000...50_000,
                    step: 1_000
                )
                Button("Apply", action: apply)
            }
            Section {
                ControlGroup {
                    Button("Export JSON…") { export(.json) }
                    Button("Export CSV…") { export(.csv) }
                }
                Button("Clear Connection History…", role: .destructive, action: clear)
            } header: {
                Text("Data")
            } footer: {
                Text("Privacy-hide rules produce no Monitor event, stored history, usage value, or aggregate count.")
            }
        }
        .formStyle(.grouped)
    }
}
