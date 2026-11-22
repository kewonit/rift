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
    @AppStorage("notificationsEnabled") private var notificationsEnabled = false
    @State private var mode: OperationMode = .silentAllow
    @State private var profiles: [PolicyProfile] = []
    @State private var activeProfileID: UUID?
    @State private var snapshot = StatusMenuSnapshot.empty
    @State private var temporaryRules: [StatusTemporaryRule] = []
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
                status: session.protectionStatus,
                mode: mode,
                profile: activeProfileName,
                snapshot: snapshot,
                now: dashboardNow,
                keepsHistory: !controller.isMinimalActivity,
                notificationsEnabled: session.isUIFixture ? fixtureNotificationsEnabled : notificationsEnabled,
                canChangeMode: !session.isUIFixture && controller.desiredPolicyTuple != nil
                    && !ConfigurationLock.shared.isLocked,
                artworkStore: session.applicationArtwork,
                selectMode: requestMode,
                performAction: perform,
                toggleNotifications: toggleNotifications,
                openConnection: openActivity,
                decideForFiveMinutes: decideForFiveMinutes
            )
            if session.review.count > 0 {
                StatusMenuButton(action: openReview) {
                    Label(ReviewBannerCopy.message(session.review.queue), systemImage: "checklist")
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help("Allow or block each in one click")
            }
            StatusMenuBlockedList(
                items: snapshot.recentlyBlocked,
                now: dashboardNow,
                artworkStore: session.applicationArtwork,
                open: openActivity,
                allowForFiveMinutes: { decideForFiveMinutes($0, .allow) }
            )
            StatusMenuTemporaryRules(
                rules: temporaryRules,
                now: dashboardNow,
                makePermanent: makePermanent,
                remove: removeRule
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
        // Rules made elsewhere, such as from an alert, show up while the panel is open.
        .onChange(of: controller.desiredPolicyTuple) { _, _ in
            if windowIsVisible { refreshCoordinator.request { await load() } }
        }
        .modifier(ModeChangeConfirmation(pendingMode: $pendingMode, confirm: setMode))
        .riftAnnounces(errorMessage)
        .riftAnnounces(profileActivationMessage)
        .confirmationDialog("Quit Rift?", isPresented: $showingQuitConfirmation, titleVisibility: .visible) {
            Button("Quit Rift", role: .destructive) { NSApplication.shared.terminate(nil) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(mode.quitMessage)
        }
    }

    @ViewBuilder
    private var messages: some View {
        let lines: [(String, Bool)] = [
            errorMessage.map { ($0, true) },
            controller.actionResults.current.map { ($0.message, $0.tone != .success) },
            profileActivationMessage.map { ($0, profileActivationNeedsAttention) },
            controller.lostEventCount > 0 ? (String(localized: "Some activity wasn’t recorded while Rift was unavailable."), false) : nil,
        ].compactMap { $0 }
        ForEach(lines, id: \.0) { line in
            // A symbol as well as the color marks what needs attention.
            (line.1 ? Text("\(Image(systemName: "exclamationmark.triangle.fill")) \(line.0)") : Text(line.0))
                .font(.caption)
                .foregroundStyle(line.1 ? Color(nsColor: .systemOrange) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(line.1 ? String(localized: "Needs attention: \(line.0)") : line.0)
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
            if ConfigurationLock.shared.isLocked {
                StatusMenuActionRow(title: "Unlock Configuration…", trailing: String(localized: "Locked")) {
                    Task { await ConfigurationLock.shared.unlock(untilQuit: false) }
                }
                .help("Unlock with Touch ID or your login password to change the mode, profile or rules")
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
                StatusMenuActionRow(title: "Status", action: {
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

    private func perform(_ action: ProtectionStatus.Action) {
        switch action {
        case .setUp, .showStatus:
            session.destination = .health
            showMainWindow()
        case .openSystemSettings:
            session.lifecycle?.openSystemSettings()
        case .reviewWaiting:
            openNextAlert()
        case .resumeRules:
            setMode(PausedModeMemory.resumeMode)
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
        if target.needsConfirmation { pendingMode = target } else { setMode(target) }
    }

    private func setMode(_ target: OperationMode) {
        pendingMode = nil
        guard !session.isUIFixture else { return }
        if target == .filterOff { PausedModeMemory.remember(mode) }
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
                errorMessage = ConfigurationLock.message(for: error) ?? String(localized: "Couldn’t change the mode. Try again.")
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
                errorMessage = ConfigurationLock.message(for: error) ?? String(localized: "Couldn’t switch profiles. Try again.")
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
        PromptPanelController.shared.bringForward()
    }

    private func toggleNotifications() {
        if session.isUIFixture {
            fixtureNotificationsEnabled.toggle()
            return
        }
        // Notifications are a setting, so the lock covers them too.
        guard ConfigurationLock.shared.permits(.byHand) else {
            errorMessage = ConfigurationLockCopy.lockedMessage
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
                errorMessage = granted ? nil : String(localized: "Notifications aren’t allowed. Turn them on in System Settings › Notifications.")
            } catch {
                notificationsEnabled = false
                errorMessage = String(localized: "Rift couldn’t ask for notification permission. Try again.")
            }
        }
    }

    private func openReview() {
        session.destination = .liveMap
        session.review.isPresented = true
        showMainWindow()
    }

    private func openActivity(_ eventID: String) {
        if cache.rows.first(where: { $0.id == eventID })?.decision == .denied {
            controller.markRecentDenyViewed()
        }
        session.requestedMonitorEventID = eventID
        session.destination = .liveMap
        showMainWindow()
    }

    // MARK: Quick rules

    /// Allows or blocks a recent connection for five minutes, the same way
    /// the Map does, with the narrowest useful scope.
    private func decideForFiveMinutes(_ eventID: String, _ action: FilterAction) {
        let results = controller.actionResults
        guard !session.isUIFixture,
              let row = cache.rows.first(where: { $0.id == eventID }),
              let breadth = MonitorRuleScope.options(for: [row]).first else {
            results.post(String(localized: "Rift can’t make a rule for this connection here. Open it in Rift."), tone: .failure)
            return
        }
        Task {
            do {
                let change = try await controller.applyMonitorRule(
                    for: row, action: action, breadth: breadth, duration: .fiveMinutes
                )
                let done = action == .deny ? String(localized: "Blocked for 5 minutes.") : String(localized: "Allowed for 5 minutes.")
                if let result = change.result {
                    results.post(
                        result.requiresAttention ? "\(done) \(result.message)" : done,
                        tone: result.requiresAttention ? .pending : .success,
                        ruleIDs: change.ruleIDs,
                        offersUndo: true
                    )
                } else {
                    results.post(action == .deny ? String(localized: "This is already blocked.") : String(localized: "This is already allowed."),
                                 ruleIDs: change.ruleIDs)
                }
                await load()
            } catch ControlPlaneController.RuleCommandError.elevatedOverrideRequiresConfirmation {
                results.post(String(localized: "This destination is on a blocklist. Open it in Rift to allow it."), tone: .failure)
            } catch ControlPlaneController.RuleCommandError.permanentRuleConflict {
                results.post(action == .deny ? String(localized: "A permanent rule allows this. Change it in Rift.")
                    : String(localized: "A permanent rule blocks this. Change it in Rift."), tone: .failure)
            } catch ControlPlaneController.RuleCommandError.overriddenByRule {
                results.post(String(localized: "Nothing changed, because another rule still decides this connection."), tone: .failure)
            } catch ControlPlaneController.RuleCommandError.incomingBlocklistOverride {
                results.post(String(localized: "This address is on a blocklist. To let it in, turn off its entry in Settings › Blocklists."), tone: .failure)
            } catch {
                results.post(String(localized: "The rule wasn’t added. Try again in Rift."), tone: .failure)
            }
        }
    }

    private func makePermanent(_ id: UUID) {
        guard let generation = controller.desiredPolicyTuple?.generation else { return }
        Task {
            do {
                try await controller.makeRulesPermanent([id], expectedGeneration: generation)
            } catch {
                controller.actionResults.post(String(localized: "The rule wasn’t changed. Try again."), tone: .failure)
            }
            await load()
        }
    }

    private func removeRule(_ id: UUID) {
        guard let generation = controller.desiredPolicyTuple?.generation else { return }
        Task {
            do {
                try await controller.deleteRules([id], expectedGeneration: generation)
            } catch {
                controller.actionResults.post(String(localized: "The rule wasn’t removed. Try again."), tone: .failure)
            }
            await load()
        }
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
        let running = await controller.runningTemporaryRules(now: Date(), limit: 4)
        if windowIsVisible, !Task.isCancelled, temporaryRules != running { temporaryRules = running }
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
