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
    @State private var recent: [MonitorEventRow] = []
    @State private var sourceSnapshot: MonitorRowsSnapshot?
    @State private var refreshCoordinator = VisualRefreshCoordinator()
    @State private var windowIsVisible = false
    @State private var showingObserveOnlyConfirmation = false
    @State private var showingQuitConfirmation = false
    @State private var profileActivationMessage: String?
    @State private var profileActivationNeedsAttention = false
    @State private var errorMessage: String?
    @State private var fixtureNotificationsEnabled = true

    private var controller: ControlPlaneController { session.controlPlane }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusMenuDashboard(
                status: statusLabel,
                mode: modeLabel,
                profile: activeProfileName,
                filteringConfirmed: session.isUIFixture || session.hasConfirmedFilterService,
                pendingCount: controller.pendingPrompts.count,
                notificationsEnabled: session.isUIFixture
                    ? fixtureNotificationsEnabled : notificationsEnabled,
                rows: recent,
                recentLimit: configuredRecentLimit,
                now: dashboardNow,
                artworkStore: session.applicationArtwork,
                toggleNotifications: toggleNotifications,
                openLiveMap: {
                    session.destination = .liveMap
                    showMainWindow()
                },
                openActivity: openActivity
            )
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
                Text("Some activity wasn’t recorded while Rift was unavailable.")
                    .font(.caption)
            }
            Divider()
            if !controller.pendingPrompts.isEmpty && !session.isUIFixture {
                StatusMenuActionRow("Open Next Alert", action: openNextAlert)
            }
            if !session.isUIFixture && mode == .filterOff {
                StatusMenuActionRow("Resume Filtering", action: { setFilteringEnabled(true) })
            } else if !session.isUIFixture {
                StatusMenuActionRow(
                    "Switch to Observe Only…",
                    action: { showingObserveOnlyConfirmation = true }
                )
            }
            if !profiles.isEmpty {
                Menu {
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
                } label: {
                    StatusMenuRowLabel(
                        title: "Switch Profile",
                        trailing: activeProfileName,
                        showsChevron: true
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            StatusMenuActionRow("Open Rift", action: showMainWindow)
            StatusMenuActionRow("Manage Rules…") {
                session.destination = .rules
                showMainWindow()
            }
            if !session.isUIFixture {
                StatusMenuActionRow("Filter Status…") {
                    session.destination = .health
                    showMainWindow()
                }
            }
            StatusMenuActionRow("Settings…") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openSettings()
            }
            Divider()
            StatusMenuActionRow("Quit Rift…", action: requestQuit)
        }
        .frame(width: 292)
        .padding(10)
        .font(.system(size: 12.5, weight: .regular))
        .onAppear {
            refreshCoordinator.request(immediate: true) { await load() }
        }
        .background(ActivityWindowVisibility(changed: visibilityChanged))
        .onDisappear {
            refreshCoordinator.stop()
            if windowIsVisible { session.monitorDidDisappear(menu: true) }
            windowIsVisible = false
            recent.removeAll(keepingCapacity: false)
            sourceSnapshot = nil
        }
        .modifier(ActivityRefreshSignal(controller: controller, changed: {
            refreshCoordinator.request { await loadActivity() }
        }))
        .onChange(of: notificationsEnabled) { _, _ in controller.requestActivitySubscriptionUpdate() }
        .confirmationDialog(
            "Switch to Observe Only?",
            isPresented: $showingObserveOnlyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Switch to Observe Only") { setFilteringEnabled(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rift will allow all connections and stop applying your rules. You’ll still see activity.")
        }
        .confirmationDialog(
            "Quit Rift?",
            isPresented: $showingQuitConfirmation,
            titleVisibility: .visible
        ) {
            Button("Quit Rift", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your rules stay active, but Rift can’t ask about new connections, and activity may have gaps until you open Rift again.")
        }
    }

    private var statusLabel: String {
        if session.isUIFixture { return "Preview — not filtering" }
        switch controller.state {
        case .connected(.ready):
            guard session.hasConfirmedFilterService else { return "Rift needs attention" }
            switch controller.currentMode {
            case .filterOff: return "Rift is observing"
            case .degradedFallback: return "Rift needs attention"
            default: return "Rift is filtering"
            }
        case .connected: return "Rift needs attention"
        case .databaseReady: return "Connecting…"
        case .integrationUnavailable: return "Can’t reach the filter"
        case .failed: return "Rift needs attention"
        case .idle: return "Starting…"
        }
    }

    private var modeLabel: String {
        switch mode {
        case .alert: return "Alert"
        case .silentAllow: return "Silent Allow"
        case .silentDeny: return "Silent Deny"
        case .filterOff: return "Observe Only"
        case .degradedFallback: return "Fallback"
        }
    }

    private var activeProfileName: String {
        profiles.first { $0.id == activeProfileID }?.name ?? "None"
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
                refreshCoordinator.request(immediate: true) { await load() }
            } catch {
                profileActivationMessage = nil
                profileActivationNeedsAttention = false
                errorMessage = "Couldn’t change the mode. Try again."
            }
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
        if recent.first(where: { $0.id == eventID }).map({
            $0.event.reason == .concreteDecision && $0.event.action == .deny
        }) == true {
            controller.markRecentDenyViewed()
        }
        session.requestedMonitorEventID = eventID
        session.destination = .activity
        showMainWindow()
    }

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
        if visible { controller.monitorDidAppear(menu: true) }
        else {
            session.monitorDidDisappear(menu: true)
            recent.removeAll(keepingCapacity: false)
            sourceSnapshot = nil
        }
        refreshCoordinator.setVisible(visible)
        if visible { refreshCoordinator.request(immediate: true) { await load() } }
    }

    private func loadActivity() async {
        guard windowIsVisible else { return }
        let interval = ActivityPerformance.signposter.beginInterval("Menu Refresh")
        defer { ActivityPerformance.signposter.endInterval("Menu Refresh", interval) }
        guard let snapshot = try? await controller.monitorRowsSnapshot(
            maximum: 1_000, previous: sourceSnapshot
        ), windowIsVisible, !Task.isCancelled else { return }
        sourceSnapshot = snapshot
        if recent != snapshot.rows { recent = snapshot.rows }
    }
}

private struct StatusMenuActionRow: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            StatusMenuRowLabel(title: title)
                .background(
                    isHovered ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct StatusMenuRowLabel: View {
    let title: String
    var trailing: String?
    var showsChevron = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12.5, weight: .regular))
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 23)
        .padding(.horizontal, 3)
        .contentShape(Rectangle())
    }
}

#if DEBUG
struct StatusMenuFixtureHost: View {
    @Bindable var session: AppSession

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            StatusMenuView(session: session)
                .background(
                    .regularMaterial,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.separator.opacity(0.55))
                }
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
        }
        .frame(minWidth: 330, minHeight: 560)
    }
}
#endif
