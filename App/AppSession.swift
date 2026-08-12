import AppKit
import AbyssCore
import Foundation
import NetworkExtension
import Observation

#if DEBUG
enum AppLaunchMode: Equatable {
    case live
    case uiFixture

    static var current: AppLaunchMode {
#if ABYSS_UI_FIXTURE_DEFAULT
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
    let geolocation: GeolocationController
    let lifecycle: FilterLifecycleController?
    let applicationArtwork: ApplicationArtworkStore
    var requestedMonitorEventID: String?
    var requestedRuleIDs: Set<UUID> = []
    var showingFilterStatus = false

    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var geolocationTask: Task<Void, Never>?
    @ObservationIgnored private var observingPrompts = false
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

    var statusSymbolName: String {
        if isUIFixture { return "eye" }
        return hasConfirmedFilterService ? controlPlane.statusSymbolName : "shield.slash"
    }

    var statusAccessibilityLabel: String {
        if isUIFixture { return "Abyss preview data. Filtering is inactive." }
        return hasConfirmedFilterService
            ? controlPlane.statusAccessibilityLabel
            : "Abyss filter needs attention"
    }

#if DEBUG
    init(launchMode: AppLaunchMode = .current) {
        self.launchMode = launchMode
        applicationArtwork = ApplicationArtworkStore(uiFixture: launchMode == .uiFixture)
        if launchMode == .uiFixture {
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
            controlPlane = ControlPlaneController(runtimeMode: .uiFixture)
            geolocation = GeolocationController(fixtureEnabled: true)
            lifecycle = nil
        } else {
            controlPlane = ControlPlaneController()
            geolocation = GeolocationController()
            lifecycle = FilterLifecycleController()
        }
        start()
    }
#else
    init() {
        applicationArtwork = ApplicationArtworkStore()
        controlPlane = ControlPlaneController()
        geolocation = GeolocationController()
        lifecycle = FilterLifecycleController()
        start()
    }
#endif

    func requestFilterStatus() {
        guard !isUIFixture else { return }
        showingFilterStatus = true
    }

    func waitForGeolocation() async {
        await geolocationTask?.value
    }

    private func start() {
        guard startupTask == nil else { return }
        geolocationTask = Task { [geolocation] in
            await geolocation.start()
        }
        startupTask = Task { [controlPlane] in
            await controlPlane.start()
        }
        observePrompts()
        observeLifecycle()
        observeApplicationActivation()
        observeFilterConfiguration()
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
                if !self.isUIFixture {
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
                   !UserDefaults.standard.bool(forKey: "abyssInitialSetupPresented") {
                    UserDefaults.standard.set(true, forKey: "abyssInitialSetupPresented")
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
