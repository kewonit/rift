import AppKit
import RiftControl
import RiftCore
import Foundation
import NetworkExtension
import Observation
import UserNotifications

struct SavedMapState {
    let query: MonitorQueryState
    let sort: MonitorHierarchySort
    let selectionID: String?
    let selectedEventID: String?
}

#if DEBUG
enum AppLaunchMode: Equatable {
    case live
    case uiFixture

    static var current: AppLaunchMode {
#if RIFT_UI_FIXTURE_DEFAULT
        return .uiFixture
#else
        if MonitorFixtureData.isRequested { return .uiFixture }
        return .live
#endif
    }
}
#endif

@MainActor
@Observable
final class AppSession {
#if DEBUG
    let launchMode: AppLaunchMode
#endif
    let controlPlane: ControlPlaneController
    let lifecycle: FilterLifecycleController?
    let applicationArtwork: ApplicationArtworkStore
    var destination: AppDestination = .liveMap
    /// What the Map and Rules pages were showing, so switching pages keeps it.
    /// This is small on purpose: the rows themselves are released with the page.
    var savedMapState: SavedMapState?
    var savedRulesSearch = ""
    var requestedMonitorEventID: String?
    /// Asks the Map page to show every connection in its table.
    var showsConnectionTable = false
    var requestedRuleIDs: Set<UUID> = []
    var showingFilterStatus = false

    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var observingPrompts = false
    @ObservationIgnored private var notificationResponder: NotificationResponder?
    @ObservationIgnored private var observingLifecycle = false
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var filterConfigurationObserver: NSObjectProtocol?

    var isUIFixture: Bool {
#if DEBUG
        launchMode == .uiFixture
#else
        false
#endif
    }

    var hasConfirmedFilterService: Bool {
        if isUIFixture { return false }
        guard let lifecycle,
              lifecycle.initialStatusResolved,
              lifecycle.state == .enabled,
              case .connected(.ready) = controlPlane.state,
              controlPlane.lastHandshake?.providerEpoch != nil,
              let desired = controlPlane.desiredPolicyTuple,
              controlPlane.activePolicyTuple == desired else { return false }
        return true
    }

    /// What Rift is doing right now. Status, the menu-bar panel and the Map
    /// all read this, so they can't disagree.
    var protectionStatus: ProtectionStatus {
#if DEBUG
        if isUIFixture {
            return ProtectionStatus.resolve(
                FixturePreviewOptions.statusInputs ?? ProtectionInputs(isPreview: true)
            )
        }
#endif
        return ProtectionStatus.resolve(protectionInputs)
    }

    private var protectionInputs: ProtectionInputs {
        let controller: ProtectionInputs.Controller = switch controlPlane.state {
        case .idle, .databaseReady: .starting
        case .connected(let readiness): .connected(readiness)
        case .integrationUnavailable: .unreachable
        case .failed: .failed
        }
        let desired = controlPlane.desiredPolicyTuple
        let active = controlPlane.activePolicyTuple
        let unreadable = controlPlane.configurationRecoveryRequired
        return ProtectionInputs(
            buildCanFilter: lifecycle?.buildCanFilter ?? true,
            lifecycle: lifecycle?.initialStatusResolved == true ? lifecycle?.state : nil,
            lifecycleTitle: lifecycle?.title,
            controller: controller,
            filterServiceConfirmed: hasConfirmedFilterService,
            hasActivePolicy: active != nil,
            desiredKnown: desired != nil,
            rulesMatchDesired: desired != nil && active == desired,
            mode: unreadable ? nil : controlPlane.currentMode,
            configurationUnreadable: unreadable,
            waitingPrompts: controlPlane.pendingPrompts.count
        )
    }

    /// Reverses the last rule change, or redoes it after an undo.
    func undoRuleChange() {
        let controller = controlPlane
        let wasRedo = controller.ruleChanges.isRedo
        Task { @MainActor in
            do {
                let result = try await controller.undoLastRuleChange()
                let needsAttention = result?.requiresAttention == true
                controller.actionResults.post(
                    needsAttention ? result?.message ?? "" : (wasRedo ? "Redone." : "Undone."),
                    tone: needsAttention ? .pending : .success,
                    offersUndo: true
                )
            } catch {
                controller.actionResults.post("Couldn’t undo because your rules changed.", tone: .failure)
            }
        }
    }

    func resumeRules() {
        guard !isUIFixture else { return }
        let results = controlPlane.actionResults
        let mode = PausedModeMemory.resumeMode
        Task { @MainActor in
            do {
                _ = try await controlPlane.setEffectiveMode(mode)
                results.post("Rules are back on, using \(mode.displayName).")
            } catch {
                results.post("Couldn’t turn rules back on. Try again.", tone: .failure)
            }
        }
    }

    var statusSymbolName: String {
        let status = protectionStatus
        if case .active = status.state, controlPlane.recentDenyVisible { return "xmark.shield.fill" }
        return status.symbolName
    }

    var statusAccessibilityLabel: String {
        let status = protectionStatus
        return "\(status.title). \(status.detail)"
    }

#if DEBUG
    init(launchMode: AppLaunchMode = .current) {
        self.launchMode = launchMode
        applicationArtwork = ApplicationArtworkStore(uiFixture: launchMode == .uiFixture)
        if launchMode == .uiFixture {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-fixture") {
                NSApplication.shared.appearance = NSAppearance(
                    named: arguments.contains("--ui-fixture-dark") ? .darkAqua : .aqua
                )
            }
            if arguments.contains("--ui-fixture-float") {
                Self.floatFixtureWindows()
            } else if FixturePreviewOptions.opensOnMonitor {
                Self.moveFixtureWindowsToMonitor()
            }
            if let page = FixturePreviewOptions.initialPage { destination = page }
            if arguments.contains("--ui-fixture-table") {
                showsConnectionTable = true
            }
            if arguments.contains("--ui-fixture-hide") {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    NSApplication.shared.hide(nil)
                }
            }
            controlPlane = ControlPlaneController(runtimeMode: .uiFixture)
            lifecycle = nil
        } else {
            controlPlane = ControlPlaneController()
            lifecycle = FilterLifecycleController()
        }
        start()
        if launchMode == .uiFixture, let count = FixturePreviewOptions.panelPromptCount {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                controlPlane.pendingPrompts = AlertFixtureHost.samplePrompts(
                    count: count, deadline: Date().addingTimeInterval(30)
                )
            }
        }
        if launchMode == .uiFixture, MonitorFixtureData.scenario == .burst {
            MonitorFixtureStream.startDriver(controlPlane)
        }
    }
#else
    init() {
        applicationArtwork = ApplicationArtworkStore()
        controlPlane = ControlPlaneController()
        lifecycle = FilterLifecycleController()
        start()
    }
#endif

#if DEBUG
    /// Keeps preview windows above other apps without taking keyboard focus, so
    /// screenshots of the map can render.
    private static func floatFixtureWindows() {
        Task { @MainActor in
            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(500))
                let sharpest = FixturePreviewOptions.monitor
                    ?? NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
                for window in NSApplication.shared.windows where window.isVisible && window.frame.width > 300 {
                    if let sharpest, window.screen != sharpest {
                        let area = sharpest.visibleFrame
                        window.setFrameOrigin(NSPoint(
                            x: area.midX - window.frame.width / 2,
                            y: area.midY - window.frame.height / 2
                        ))
                    }
                    if FixturePreviewOptions.usesMinimumSize {
                        window.setContentSize(NSSize(width: 1_160, height: 600))
                    }
                    window.level = .floating
                    window.orderFrontRegardless()
                }
            }
        }
    }

    /// Moves preview windows to the external display once, then leaves them to
    /// be used normally.
    private static func moveFixtureWindowsToMonitor() {
        Task { @MainActor in
            guard let area = FixturePreviewOptions.monitor?.visibleFrame else { return }
            var moved = Set<ObjectIdentifier>()
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(250))
                for window in NSApplication.shared.windows
                where window.isVisible && window.frame.width > 200 && !moved.contains(ObjectIdentifier(window)) {
                    moved.insert(ObjectIdentifier(window))
                    window.setFrameOrigin(NSPoint(
                        x: area.midX - window.frame.width / 2,
                        y: area.midY - window.frame.height / 2
                    ))
                }
            }
        }
    }
#endif

    func requestFilterStatus() {
        guard !isUIFixture else { return }
        showingFilterStatus = true
    }

    func monitorDidDisappear(menu: Bool = false) {
        controlPlane.monitorDidDisappear(menu: menu)
    }

    private func start() {
        guard startupTask == nil else { return }
        if !isUIFixture {
            let responder = NotificationResponder(session: self)
            notificationResponder = responder
            UNUserNotificationCenter.current().delegate = responder
        }
        startupTask = Task { [controlPlane] in
            await controlPlane.start()
        }
        observePrompts()
        observeLifecycle()
        observeApplicationActivation()
        observeFilterConfiguration()
    }

    private var showsPromptPanel: Bool {
#if DEBUG
        !isUIFixture || FixturePreviewOptions.panelPromptCount != nil
#else
        true
#endif
    }

    private func observePrompts() {
        guard !observingPrompts else { return }
        observingPrompts = true
        withObservationTracking {
            _ = controlPlane.pendingPrompts
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observingPrompts = false
                if self.showsPromptPanel {
                    PromptPanelController.shared.update(
                        prompts: self.controlPlane.pendingPrompts,
                        controller: self.controlPlane,
                        artworkStore: self.applicationArtwork
                    )
                }
                self.observePrompts()
            }
        }
    }

    private func observeLifecycle() {
        guard let lifecycle, !observingLifecycle else { return }
        observingLifecycle = true
        withObservationTracking {
            _ = lifecycle.initialStatusResolved
            _ = lifecycle.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let lifecycle = self.lifecycle else { return }
                self.observingLifecycle = false
                if lifecycle.initialStatusResolved,
                   case .notInstalled = lifecycle.state,
                   !UserDefaults.standard.bool(forKey: "riftInitialSetupPresented") {
                    UserDefaults.standard.set(true, forKey: "riftInitialSetupPresented")
                    self.showingFilterStatus = true
                }
                if lifecycle.initialStatusResolved,
                   lifecycle.state.mayProvideControlService {
                    self.controlPlane.requestReconnect()
                }
                self.observeLifecycle()
            }
        }
    }

    private func observeApplicationActivation() {
        guard !isUIFixture, activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lifecycle?.refreshStatus()
                self.controlPlane.requestReconnect()
            }
        }
    }

    private func observeFilterConfiguration() {
        guard !isUIFixture, filterConfigurationObserver == nil else { return }
        filterConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .NEFilterConfigurationDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lifecycle?.refreshStatus()
                self.controlPlane.requestReconnect()
            }
        }
    }
}

private extension LifecycleState {
    var mayProvideControlService: Bool {
        switch self {
        case .active, .savingFilterConfiguration, .enabled, .replacing:
            true
        default:
            false
        }
    }
}
