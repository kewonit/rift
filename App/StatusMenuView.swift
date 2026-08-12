import AppKit
import AbyssControl
import AbyssCore
import AbyssIPC
import SwiftUI

extension ControlPlaneController {
    func markRecentDenyViewed() {
        recentDenyTask?.cancel()
        recentDenyUntil = nil
    }

    func refreshCurrentMode(_ mode: OperationMode) { currentMode = mode }

    var statusSymbolName: String {
        guard case .connected(.ready) = state else { return "shield.slash" }
        if !pendingPrompts.isEmpty { return "exclamationmark.shield" }
        if let recentDenyUntil, recentDenyUntil > Date() { return "xmark.shield.fill" }
        switch currentMode {
        case .alert: return "questionmark.shield"
        case .silentAllow: return "checkmark.shield"
        case .silentDeny: return "xmark.shield"
        case .filterOff: return "eye"
        case .degradedFallback: return "exclamationmark.shield"
        }
    }

    var statusAccessibilityLabel: String {
        guard case .connected(.ready) = state else { return "Abyss filter needs attention" }
        if !pendingPrompts.isEmpty { return "Abyss has pending connection decisions" }
        if let recentDenyUntil, recentDenyUntil > Date() {
            return "Abyss recently denied a connection"
        }
        switch currentMode {
        case .alert: return "Abyss filtering in Alert mode"
        case .silentAllow: return "Abyss filtering in Silent Allow mode"
        case .silentDeny: return "Abyss filtering in Silent Deny mode"
        case .filterOff: return "Abyss observing without filtering"
        case .degradedFallback: return "Abyss filtering is degraded"
        }
    }

    func recordRecentDeny(from events: [RuntimeEvent]) {
        guard let deniedAt = events.lazy
            .filter({ $0.kind == .decision && $0.action == .deny })
            .map(\.occurredAt)
            .max() else { return }
        let expiry = deniedAt.addingTimeInterval(30)
        guard expiry > Date() else { return }
        recentDenyUntil = expiry
        recentDenyTask?.cancel()
        recentDenyTask = Task { [weak self] in
            let delay = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self?.recentDenyUntil == expiry else { return }
            self?.recentDenyUntil = nil
        }
    }
}

struct StatusMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var session: AppSession
    @AppStorage("statusPreviousFilteringMode") private var previousMode = OperationMode.silentAllow.rawValue
    @State private var mode: OperationMode = .silentAllow
    @State private var profiles: [PolicyProfile] = []
    @State private var activeProfileID: UUID?
    @State private var recent: [MonitorEventRow] = []
    @State private var showingObserveOnlyConfirmation = false
    @State private var showingQuitConfirmation = false
    @State private var profileActivationMessage: String?
    @State private var profileActivationNeedsAttention = false
    @State private var errorMessage: String?

    private var controller: ControlPlaneController { session.controlPlane }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(statusLabel).font(.headline)
            Text("Mode: \(modeLabel)")
            Text("Profile: \(activeProfileName)")
            Text("\(controller.pendingPrompts.count) pending")
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange)
            }
            if let profileActivationMessage {
                Text(profileActivationMessage)
                    .font(.caption)
                    .foregroundStyle(
                        profileActivationNeedsAttention
                            ? Color.orange : Color(nsColor: .secondaryLabelColor)
                    )
            }
            if controller.lostEventCount > 0 {
                Text("Some activity was dropped while the app was unavailable.")
                    .font(.caption)
            }
            Divider()
            Button("Open Next Alert") {
                PromptPanelController.shared.update(
                    prompts: controller.pendingPrompts,
                    controller: controller,
                    artworkStore: session.applicationArtwork
                )
            }
            .disabled(controller.pendingPrompts.isEmpty || session.isUIFixture)
            if !session.isUIFixture && mode == .filterOff {
                Button("Resume Filtering") { setFilteringEnabled(true) }
            } else if !session.isUIFixture {
                Button("Switch to Observe Only…") { showingObserveOnlyConfirmation = true }
            }
            if !profiles.isEmpty {
                Menu("Switch Profile") {
                    Button("None") { activateProfile(nil) }
                    ForEach(profiles) { profile in
                        Button {
                            activateProfile(profile.id)
                        } label: {
                            if profile.id == activeProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                }
            }
            if !recent.isEmpty {
                Divider()
                Text("Recent activity").font(.caption).foregroundStyle(.secondary)
                ForEach(recent) { row in
                    Button("\(activityLabel(row)) • \(row.event.occurredAt.formatted(date: .omitted, time: .shortened))") {
                        if row.event.reason == .concreteDecision,
                           row.event.action == .deny {
                            controller.markRecentDenyViewed()
                        }
                        session.requestedMonitorEventID = row.id
                        showMainWindow()
                    }
                }
            }
            Divider()
            Button("Open Abyss") { showMainWindow() }
            Button("Rules…") { showRulesWindow() }
            if !session.isUIFixture {
                Button("Filter Status…") {
                    session.requestFilterStatus()
                    showMainWindow()
                }
            }
            SettingsLink { Text("Settings…") }
            Button("Quit Abyss…") { requestQuit() }
        }
        .padding(10)
        .onAppear {
            Task { await load() }
        }
        .confirmationDialog(
            "Switch to Observe Only?",
            isPresented: $showingObserveOnlyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Switch to Observe Only") { setFilteringEnabled(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Abyss will continue observing visible connections but will allow them instead of applying allow, deny, or ask verdicts.")
        }
        .confirmationDialog(
            "Quit Abyss?",
            isPresented: $showingQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Quit Abyss", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Loaded rules keep enforcing, but prompts cannot appear and activity history may have gaps until Abyss reopens.")
        }
    }

    private var statusLabel: String {
        if session.isUIFixture { return "Preview — not filtering" }
        switch controller.state {
        case .connected(.ready):
            guard session.hasConfirmedFilterService else { return "Abyss needs attention" }
            switch controller.currentMode {
            case .filterOff: return "Abyss is observing"
            case .degradedFallback: return "Abyss needs attention"
            default: return "Abyss is enforcing"
            }
        case .connected: return "Abyss needs attention"
        case .databaseReady: return "Connecting…"
        case .integrationUnavailable: return "Filter connection unavailable"
        case .failed: return "Abyss needs attention"
        case .idle: return "Starting…"
        }
    }

    private var modeLabel: String {
        if session.isUIFixture { return "Preview" }
        switch mode {
        case .alert: return "Alert"
        case .silentAllow: return "Silent Allow"
        case .silentDeny: return "Silent Deny"
        case .filterOff: return "Observe only"
        case .degradedFallback: return "Degraded fallback"
        }
    }

    private var activeProfileName: String {
        profiles.first { $0.id == activeProfileID }?.name ?? "None"
    }

    private func activateProfile(_ id: UUID?) {
        Task {
            do {
                let result = try await controller.activateProfile(id)
                profileActivationMessage = result.message
                profileActivationNeedsAttention = result != .enforced(backupFailed: false)
                errorMessage = nil
                await load()
            } catch {
                profileActivationMessage = nil
                profileActivationNeedsAttention = false
                errorMessage = "The active profile was not changed."
            }
        }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func showRulesWindow() {
        openWindow(id: "rules")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func requestQuit() {
        if session.isUIFixture || (mode == .filterOff && controller.pendingPrompts.isEmpty) {
            NSApplication.shared.terminate(nil)
        } else {
            showingQuitConfirmation = true
        }
    }

    private func setFilteringEnabled(_ enabled: Bool) {
        guard !session.isUIFixture else { return }
        Task {
            do {
                let target: OperationMode
                if enabled {
                    target = OperationMode(rawValue: previousMode).flatMap {
                        $0 == .filterOff || $0 == .degradedFallback ? nil : $0
                    } ?? .silentAllow
                } else {
                    if mode != .filterOff && mode != .degradedFallback { previousMode = mode.rawValue }
                    target = .filterOff
                }
                let result = try await controller.setEffectiveMode(target)
                profileActivationMessage = result.requiresAttention ? result.message : nil
                profileActivationNeedsAttention = result.requiresAttention
                errorMessage = nil
                await load()
            } catch {
                profileActivationMessage = nil
                profileActivationNeedsAttention = false
                errorMessage = "The filtering mode was not saved."
            }
        }
    }

    private func activityLabel(_ row: MonitorEventRow) -> String {
        if row.event.reason != .concreteDecision { return "Fallback" }
        return row.event.action == .deny ? "Denied" : "Allowed"
    }

    private func load() async {
        if let presentation = try? await controller.policyPresentation() {
            mode = presentation.effectiveMode
        }
        if let definitions = try? await controller.policyDefinitions() {
            profiles = definitions.profiles
            activeProfileID = definitions.active
        }
        let configuredLimit = UserDefaults.standard.object(forKey: "statusRecentLimit") == nil
            ? 10 : UserDefaults.standard.integer(forKey: "statusRecentLimit")
        let limit = min(max(configuredLimit, 0), 25)
        guard limit > 0 else {
            recent = []
            return
        }
        if let rows = try? await controller.monitorPage(limit: 100) {
            recent = Array(rows.prefix(limit))
        }
    }
}
