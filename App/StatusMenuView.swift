import AppKit
import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

extension ControlPlaneController {
    func markRecentDenyViewed() {
        recentDenyTask?.cancel()
        recentDenyUntil = nil
        recentDenyVisible = false
    }

    func refreshCurrentMode(_ mode: OperationMode) { currentMode = mode }

    var statusSymbolName: String {
        guard case .connected(.ready) = state else { return "shield.slash" }
        if !pendingPrompts.isEmpty { return "exclamationmark.shield" }
        if recentDenyVisible { return "xmark.shield.fill" }
        switch currentMode {
        case .alert: return "questionmark.shield"
        case .silentAllow: return "checkmark.shield"
        case .silentDeny: return "xmark.shield"
        case .filterOff: return "eye"
        case .degradedFallback: return "exclamationmark.shield"
        }
    }

    var statusAccessibilityLabel: String {
        guard case .connected(.ready) = state else { return "The Rift filter needs attention" }
        if !pendingPrompts.isEmpty { return "Rift has connections waiting for your decision" }
        if recentDenyVisible {
            return "Rift recently denied a connection"
        }
        switch currentMode {
        case .alert: return "Rift is filtering in Alert mode"
        case .silentAllow: return "Rift is filtering in Silent Allow mode"
        case .silentDeny: return "Rift is filtering in Silent Deny mode"
        case .filterOff: return "Rift is observing without filtering"
        case .degradedFallback: return "Rift is running in fallback mode"
        }
    }

    func recordRecentDeny(from events: [RuntimeEvent]) {
        guard let deniedAt = events.lazy
            .filter({ $0.kind == .decision && $0.action == .deny })
            .map(\.occurredAt)
            .max() else { return }
        recordRecentDeny(at: deniedAt)
    }

    func recordRecentDeny(at deniedAt: Date) {
        let expiry = deniedAt.addingTimeInterval(30)
        guard expiry > Date() else { return }
        recentDenyUntil = expiry
        if !recentDenyVisible { recentDenyVisible = true }
        recentDenyTask?.cancel()
        recentDenyTask = Task { [weak self] in
            let delay = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self?.recentDenyUntil == expiry else { return }
            self?.recentDenyUntil = nil
            self?.recentDenyVisible = false
        }
    }
}

struct StatusMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Bindable var session: AppSession
    @AppStorage("statusPreviousFilteringMode") private var previousMode = OperationMode.silentAllow.rawValue
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @State private var mode: OperationMode = .silentAllow
    @State private var profiles: [PolicyProfile] = []
    @State private var activeProfileID: UUID?
    @State private var snapshot = StatusMenuSnapshot.empty
    /// Loading state the view never displays; a reference so updating it
    /// doesn't redraw the panel.
    @State private var cache = StatusMenuLoadCache()
    @State private var refreshCoordinator = VisualRefreshCoordinator()
    @State private var windowIsVisible = false
    @State private var pendingMode: OperationMode?
    @State private var showingQuitConfirmation = false
    @State private var profileActivationMessage: String?
    @State private var profileActivationNeedsAttention = false
    @State private var errorMessage: String?
    @State private var fixtureNotificationsEnabled = true

    private var controller: ControlPlaneController { session.controlPlane }

    var body: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.s) {
            StatusMenuDashboard(
                status: status,
                mode: mode,
                profile: activeProfileName,
                snapshot: snapshot,
                now: dashboardNow,
                notificationsEnabled: session.isUIFixture ? fixtureNotificationsEnabled : notificationsEnabled,
                canChangeMode: !session.isUIFixture,
                artworkStore: session.applicationArtwork,
                selectMode: requestMode,
                toggleNotifications: toggleNotifications,
                openConnection: openActivity
            )
            messages
            Divider().padding(.vertical, RiftDesign.Spacing.xxs)
            commands
        }
        .frame(width: 300)
        .padding(RiftDesign.Spacing.m)
        .onAppear {
            refreshCoordinator.request(immediate: true) { await load() }
        }
        .background(ActivityWindowVisibility(changed: visibilityChanged))
        .onDisappear {
            refreshCoordinator.stop()
            if windowIsVisible { session.monitorDidDisappear(menu: true) }
            windowIsVisible = false
            releaseActivity()
        }
        .modifier(ActivityRefreshSignal(controller: controller, changed: {
            refreshCoordinator.request { await loadActivity() }
        }))
        .onChange(of: notificationsEnabled) { _, _ in controller.requestActivitySubscriptionUpdate() }
        .confirmationDialog(
            pendingMode == .filterOff ? "Switch to Observe Only?" : "Switch to Silent Deny?",
            isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
            titleVisibility: .visible
        ) {
            if let pendingMode {
                Button("Switch to \(pendingMode.menuTitle)") { setMode(pendingMode) }
            }
            Button("Cancel", role: .cancel) { pendingMode = nil }
        } message: {
            Text(pendingMode == .filterOff
                ? "Rift will allow all connections and stop applying your rules. You’ll still see activity."
                : "Rift will deny every connection that no rule allows. Apps without an allow rule lose network access.")
        }
        .confirmationDialog("Quit Rift?", isPresented: $showingQuitConfirmation, titleVisibility: .visible) {
            Button("Quit Rift", role: .destructive) { NSApplication.shared.terminate(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your rules stay active, but Rift can’t ask about new connections, and activity may have gaps until you open Rift again.")
        }
    }

    @ViewBuilder
    private var messages: some View {
        let lines: [(String, Bool)] = [
            errorMessage.map { ($0, true) },
            profileActivationMessage.map { ($0, profileActivationNeedsAttention) },
            controller.lostEventCount > 0 ? ("Some activity wasn’t recorded while Rift was unavailable.", false) : nil,
        ].compactMap { $0 }
        ForEach(lines, id: \.0) { line in
            Text(line.0)
                .font(.caption)
                .foregroundStyle(line.1 ? Color(nsColor: .systemOrange) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var commands: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !controller.pendingPrompts.isEmpty && !session.isUIFixture {
                StatusMenuActionRow(
                    title: "Review Waiting Connections",
                    trailing: String(controller.pendingPrompts.count),
                    action: openNextAlert
                )
            }
            if !profiles.isEmpty {
                Menu {
                    Button("None") { activateProfile(nil) }
                    ForEach(profiles) { profile in
                        Button { activateProfile(profile.id) } label: {
                            if profile.id == activeProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("Profile")
                        Spacer(minLength: RiftDesign.Spacing.s)
                        Text(activeProfileName ?? "None").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, RiftDesign.Spacing.xs + 2)
                    .frame(maxWidth: .infinity, minHeight: 26)
                }
                .menuStyle(.borderlessButton)
                .fixedSize(horizontal: false, vertical: true)
            }
            StatusMenuActionRow(title: "Open Map", shortcut: "⌘O", action: {
                session.destination = .liveMap
                showMainWindow()
            })
            .keyboardShortcut("o", modifiers: .command)
            StatusMenuActionRow(title: "Rules", action: {
                session.destination = .rules
                showMainWindow()
            })
            if !session.isUIFixture {
                StatusMenuActionRow(title: "Filter Status", action: {
                    session.destination = .health
                    showMainWindow()
                })
            }
            StatusMenuActionRow(title: "Settings…", shortcut: "⌘,", action: {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            })
            Divider().padding(.vertical, RiftDesign.Spacing.xs)
            StatusMenuActionRow(title: "Quit Rift", shortcut: "⌘Q", action: requestQuit)
        }
    }

    private var status: StatusMenuStatus {
        if session.isUIFixture { return StatusMenuStatus(title: "Preview", tone: .preview, detail: "Rift isn’t filtering") }
        switch controller.state {
        case .connected(.ready):
            guard session.hasConfirmedFilterService else { return .init(title: "Rift needs attention", tone: .attention) }
            if !controller.pendingPrompts.isEmpty { return .init(title: "Connections are waiting", tone: .attention) }
            switch controller.currentMode {
            case .filterOff: return .init(title: "Rift is observing", tone: .observing)
            case .degradedFallback: return .init(title: "Rift needs attention", tone: .attention)
            default: return .init(title: "Rift is filtering", tone: .good)
            }
        case .connected, .failed: return .init(title: "Rift needs attention", tone: .attention)
        case .databaseReady: return .init(title: "Connecting…", tone: .attention)
        case .integrationUnavailable: return .init(title: "Can’t reach the filter", tone: .attention)
        case .idle: return .init(title: "Starting…", tone: .attention)
        }
    }

    private var activeProfileName: String? {
        profiles.first { $0.id == activeProfileID }?.name
    }

    private var configuredRecentLimit: Int {
        let value = UserDefaults.standard.object(forKey: "statusRecentLimit") == nil
            ? 5 : UserDefaults.standard.integer(forKey: "statusRecentLimit")
        return min(max(value, 0), controller.isMinimalActivity ? 5 : 10)
    }

    private var dashboardNow: Date {
#if DEBUG
        session.isUIFixture ? MonitorFixtureData.referenceNow : Date()
#else
        Date()
#endif
    }

    // MARK: Actions

    private func requestMode(_ target: OperationMode) {
        guard target != mode, !session.isUIFixture else { return }
        if target == .filterOff || target == .silentDeny { pendingMode = target } else { setMode(target) }
    }

    private func setMode(_ target: OperationMode) {
        pendingMode = nil
        guard !session.isUIFixture else { return }
        if target == .filterOff, mode != .filterOff, mode != .degradedFallback { previousMode = mode.rawValue }
        Task {
            do {
                let result = try await controller.setEffectiveMode(target)
                profileActivationMessage = result.requiresAttention ? result.message : nil
                profileActivationNeedsAttention = result.requiresAttention
                errorMessage = nil
                refreshCoordinator.request(immediate: true) { await load() }
            } catch {
                profileActivationMessage = nil
                profileActivationNeedsAttention = false
                errorMessage = "Couldn’t change the mode. Try again."
            }
        }
    }

    private func activateProfile(_ id: UUID?) {
        Task {
            do {
                let result = try await controller.activateProfile(id)
                profileActivationMessage = result.message
                profileActivationNeedsAttention = result != .enforced(backupFailed: false)
                errorMessage = nil
                refreshCoordinator.request(immediate: true) { await load() }
            } catch {
                profileActivationMessage = nil
                profileActivationNeedsAttention = false
                errorMessage = "Couldn’t switch profiles. Try again."
            }
        }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func requestQuit() {
        if session.isUIFixture || (mode == .filterOff && controller.pendingPrompts.isEmpty) {
            NSApplication.shared.terminate(nil)
        } else {
            showingQuitConfirmation = true
        }
    }

    private func openNextAlert() {
        PromptPanelController.shared.update(
            prompts: controller.pendingPrompts,
            controller: controller,
            artworkStore: session.applicationArtwork
        )
    }

    private func toggleNotifications() {
        if session.isUIFixture {
            fixtureNotificationsEnabled.toggle()
            return
        }
        if notificationsEnabled {
            notificationsEnabled = false
            errorMessage = nil
            return
        }
        Task {
            do {
                let granted = try await controller.requestNotificationPermission()
                notificationsEnabled = granted
                errorMessage = granted ? nil : "Notifications aren’t allowed. Turn them on in System Settings › Notifications."
            } catch {
                notificationsEnabled = false
                errorMessage = "Rift couldn’t ask for notification permission. Try again."
            }
        }
    }

    private func openActivity(_ eventID: String) {
        if cache.rows.first(where: { $0.id == eventID })?.decision == .denied {
            controller.markRecentDenyViewed()
        }
        session.requestedMonitorEventID = eventID
        session.destination = .liveMap
        showMainWindow()
    }

    // MARK: Loading

    private func load() async {
        if let presentation = try? await controller.policyPresentation() {
            if windowIsVisible, !Task.isCancelled { mode = presentation.effectiveMode }
        }
        if let definitions = try? await controller.policyDefinitions() {
            if windowIsVisible, !Task.isCancelled {
                profiles = definitions.profiles
                activeProfileID = definitions.active
            }
        }
        await loadActivity()
    }

    private func visibilityChanged(_ visible: Bool) {
        guard visible != windowIsVisible else { return }
        windowIsVisible = visible
        if visible { controller.monitorDidAppear(menu: true) } else {
            session.monitorDidDisappear(menu: true)
            releaseActivity()
        }
        refreshCoordinator.setVisible(visible)
        if visible { refreshCoordinator.request(immediate: true) { await load() } }
    }

    private func releaseActivity() {
        cache.rows = []
        cache.source = nil
        snapshot = .empty
    }

    /// Loads only the last five minutes: that is all the panel shows.
    private func loadActivity() async {
        guard windowIsVisible else { return }
        let interval = ActivityPerformance.signposter.beginInterval("Menu Refresh")
        defer { ActivityPerformance.signposter.endInterval("Menu Refresh", interval) }
        let now = dashboardNow
        let window = MonitorTimeWindow(start: now.addingTimeInterval(-StatusMenuSnapshot.window), end: nil)
        guard let rows = try? await controller.monitorRowsSnapshot(
            maximum: 1_000, window: window, previous: cache.source
        ), windowIsVisible, !Task.isCancelled else { return }
        cache.source = rows
        guard cache.rows != rows.rows else { return }
        cache.rows = rows.rows
        let updated = StatusMenuSnapshot.make(rows: rows.rows, now: now, recentLimit: configuredRecentLimit)
        if snapshot != updated { snapshot = updated }
    }
}

@MainActor
private final class StatusMenuLoadCache {
    var source: MonitorRowsSnapshot?
    var rows: [MonitorEventRow] = []
}
