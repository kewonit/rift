import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case alerts = "Alerts"
    case history = "Monitor & Privacy"
    case policies = "Policies"
    case advanced = "Advanced"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .alerts: "Alerts"
        case .history: "History & Privacy"
        case .policies: "Profiles & Blocklists"
        case .advanced: "Advanced"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gear"
        case .alerts: "bell"
        case .history: "eye.slash"
        case .policies: "switch.2"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

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
                Picker("Default mode", selection: Binding(
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
                LabeledContent("Current mode", value: label(effectiveMode))
            } header: {
                Text("Filtering")
            } footer: {
                Text("Observe Only shows activity but allows all connections. A profile can use a different mode.")
            }
            Section("Startup") {
                Toggle("Open Rift at login", isOn: Binding(
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
        case .degradedFallback: "Fallback"
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
                Text("Destination details can appear on the Lock Screen. Notifications don’t change how connections are filtered.")
            }
            Section {
                Picker("Remember decisions", selection: $alertDefaultLifetime) {
                    Text("Once").tag("Once")
                    Text("One hour").tag("One hour")
                    Text("Always").tag("Always")
                }
                Picker("Apply new rules to", selection: $alertDefaultScope) {
                    Text("Current profile").tag("Current profile")
                    Text("All profiles").tag("All profiles")
                }
                Stepper("Recent apps in menu: \(recentLimit)", value: $recentLimit, in: 0...10)
            } header: {
                Text("Alert Defaults")
            } footer: {
                Text("If you don’t answer an alert in time, Rift lets the connection through.")
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
                Toggle("Save connection history", isOn: $historyEnabled)
                Stepper("Keep for \(retentionDays) \(retentionDays == 1 ? "day" : "days")", value: $retentionDays, in: 1...30)
                    .disabled(!historyEnabled)
                Stepper(
                    "Keep up to \(maximumFlows.formatted()) connections",
                    value: $maximumFlows,
                    in: 1_000...50_000,
                    step: 1_000
                )
                .disabled(!historyEnabled)
                Button("Apply", action: apply)
                Text("When history is off, Rift keeps up to \(ControlPlaneController.minimalFlowLimit) recent connections for five minutes, and only while Activity or Live Map is open (five while only the menu is open). Nothing is kept while those views are closed. Your rules still apply.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("Connections that match a “Hide from history” rule never appear in Activity, history, usage counts, or totals.")
            }
        }
        .formStyle(.grouped)
    }
}
