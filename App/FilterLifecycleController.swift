import AbyssCore
import AppKit
import NetworkExtension
import Observation
import OSLog
import SystemExtensions

@MainActor
@Observable
final class FilterLifecycleController: NSObject {
    private enum RequestKind: Equatable {
        case properties
        case activation
        case deactivation
    }

    private enum RetryAction {
        case activation
        case status
    }

    private static let extensionIdentifier = FilterActivationPreflight.extensionIdentifier
    private let logger = Logger(subsystem: "io.abyss.firewall", category: "lifecycle")
    private var machine = LifecycleStateMachine()
    private var activeRequest: OSSystemExtensionRequest?
    private var activeRequestKind: RequestKind?
    private var retryAction: RetryAction?
    private(set) var initialStatusResolved = false
    private(set) var activationPreflightFailure:
        SystemExtensionActivationPreflightFailure?

    override init() {
        super.init()
        refreshInstalledState()
    }

    var state: LifecycleState { machine.state }

    var operationInProgress: Bool {
        switch state {
        case .activating, .active, .savingFilterConfiguration, .replacing, .uninstalling:
            true
        default:
            false
        }
    }

    var shouldOfferSettings: Bool {
        switch state {
        case .awaitingApproval, .denied, .disabled, .failed:
            true
        default:
            false
        }
    }

    var shouldOfferRetry: Bool {
        initialStatusResolved && retryAction != nil && activeRequest == nil &&
            !operationInProgress
    }

    var title: String {
        switch state {
        case .notInstalled: "Ready to protect this Mac"
        case .activating: "Installing the network filter…"
        case .awaitingApproval: "Approval is required"
        case .active: "Network filter installed"
        case .savingFilterConfiguration: "Enabling the network filter…"
        case .enabled: "Abyss is active"
        case .denied: "Approval was denied"
        case .disabled: "Abyss is disabled in macOS"
        case .stale: "Refreshing filter settings…"
        case .replacing: "Updating the network filter…"
        case .failed: "Abyss needs attention"
        case .uninstalling: "Removing the network filter…"
        }
    }

    var guidance: String {
        switch state {
        case .notInstalled:
            "Install Abyss from Applications, then approve its network extension when macOS asks. Traffic remains allowed during this foundation setup."
        case .awaitingApproval:
            "Open Login Items & Extensions in System Settings, select Network Extensions, and enable Abyss. Return here when approval finishes."
        case .denied(let message), .failed(let message):
            message
        case .disabled:
            "The extension is installed but disabled outside Abyss. No filtering or activity reporting is available until it is enabled again."
        case .enabled:
            "The network provider is enabled. Abyss reports enforcement only after the control plane confirms the active policy generation."
        default:
            "Abyss is applying the requested system configuration."
        }
    }

    func installAndEnable() {
        guard activeRequest == nil, !operationInProgress else { return }
        let applicationPath = Bundle.main.bundleURL
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard applicationPath.hasPrefix("/Applications/") else {
            retryAction = .activation
            transition(.fail("Move Abyss to Applications before installing its system extension."))
            return
        }
        activationPreflightFailure = nil
        do {
            _ = try FilterActivationPreflight.validate()
        } catch LifecycleHealthFailure.activationPreflight(let failure) {
            activationPreflightFailure = failure
            retryAction = .activation
            transition(.fail(LifecycleHealthFailure.activationPreflight(failure).message))
            return
        } catch {
            let failure = SystemExtensionActivationPreflightFailure.invalidEmbeddedBundle
            activationPreflightFailure = failure
            retryAction = .activation
            transition(.fail(LifecycleHealthFailure.activationPreflight(failure).message))
            return
        }
        retryAction = nil
        transition(.requestActivation)
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        activeRequest = request
        activeRequestKind = .activation
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func uninstall() {
        guard activeRequest == nil, !operationInProgress else { return }
        transition(.beginUninstall)
        Task {
            do {
                try await removeFilterConfiguration(retryStaleOnce: true)
                submitDeactivation()
            } catch {
                retryAction = .status
                transition(.fail("macOS could not prepare the filter for removal. The error was \(sanitized(error))."))
            }
        }
    }

    func refreshStatus() {
        guard activeRequest == nil, !operationInProgress else { return }
        refreshInstalledState()
    }

    func retrySetup() {
        guard activeRequest == nil, !operationInProgress else { return }
        switch retryAction {
        case .activation:
            installAndEnable()
        case .status:
            refreshInstalledState()
        case nil:
            break
        }
    }

    private func submitDeactivation() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        activeRequest = request
        activeRequestKind = .deactivation
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func refreshInstalledState() {
        retryAction = nil
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier,
            queue: .main
        )
        request.delegate = self
        activeRequest = request
        activeRequestKind = .properties
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func copyRedactedDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(redactedDiagnostics(), forType: .string)
    }

    private func redactedDiagnostics() -> String {
        [
            "Abyss health (redacted)",
            "state=\(state)",
            "activationPreflight=\(activationPreflightFailure?.rawValue ?? "none")",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "protocol=1.0",
        ].joined(separator: "\n")
    }

    private func enableFilter() async {
        transition(.beginConfiguration)
        do {
            try await configureFilter(retryStaleOnce: true)
            refreshInstalledState()
        } catch {
            retryAction = .activation
            transition(.fail("macOS could not enable the filter. The error was \(sanitized(error)). Traffic is not claimed as filtered."))
        }
    }

    private func configureFilter(retryStaleOnce: Bool) async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        let configuration = NEFilterProviderConfiguration()
        configuration.filterSockets = true
        configuration.filterPackets = false
        configuration.organization = "Abyss"
        configuration.filterDataProviderBundleIdentifier = Self.extensionIdentifier
        configuration.filterPacketProviderBundleIdentifier = nil
        manager.providerConfiguration = configuration
        manager.localizedDescription = "Abyss Network Filter"
        manager.isEnabled = true
        do {
            try await manager.saveToPreferences()
        } catch let error as NSError where retryStaleOnce && isStale(error) {
            transition(.configurationStale)
            transition(.beginConfiguration)
            try await configureFilter(retryStaleOnce: false)
        }
    }

    private func removeFilterConfiguration(retryStaleOnce: Bool) async throws {
        let manager = NEFilterManager.shared()
        try await manager.loadFromPreferences()
        guard manager.providerConfiguration != nil else { return }
        do {
            try await manager.removeFromPreferences()
        } catch let error as NSError where retryStaleOnce && isStale(error) {
            try await removeFilterConfiguration(retryStaleOnce: false)
        }
    }

    private func isStale(_ error: NSError) -> Bool {
        error.domain == NEFilterErrorDomain &&
            error.code == NEFilterManagerError.configurationStale.rawValue
    }

    private func sanitized(_ error: Error) -> String {
        let value = error as NSError
        return "\(value.domain) (\(value.code))"
    }

    private func reconciledState(
        for observations: [InstalledExtensionObservation]
    ) async -> LifecycleState {
        guard !observations.isEmpty else { return .notInstalled }
        guard observations.count == 1 else {
            return failed(.ambiguousInstalledExtension)
        }
        let observation = observations[0]
        guard observation.identity.bundleIdentifier == Self.extensionIdentifier else {
            return failed(.installedExtensionMismatch)
        }
        if observation.uninstalling { return .uninstalling }
        if observation.awaitingApproval { return .awaitingApproval }

        let expected: ExtensionIdentity
        do {
            expected = try FilterActivationPreflight.embeddedIdentity()
        } catch let failure as LifecycleHealthFailure {
            return failed(failure)
        } catch {
            return failed(.invalidEmbeddedExtension)
        }
        guard observation.identity == expected else {
            return failed(.installedExtensionMismatch)
        }
        guard observation.enabled else { return .disabled }

        let manager = NEFilterManager.shared()
        do {
            try await manager.loadFromPreferences()
        } catch {
            return .failed(
                message: "Installed-state query failed with \(sanitized(error))."
            )
        }
        guard manager.isEnabled else { return .disabled }
        guard let configuration = manager.providerConfiguration else {
            return failed(.providerConfigurationMismatch)
        }
        guard configuration.filterDataProviderBundleIdentifier
                == Self.extensionIdentifier else {
            return failed(.providerConfigurationMismatch)
        }
        guard configuration.filterSockets else {
            return failed(.socketFilteringDisabled)
        }
        guard !configuration.filterPackets,
              configuration.filterPacketProviderBundleIdentifier == nil else {
            return failed(.packetFilteringClaimed)
        }
        return .enabled
    }

    private func failed(_ failure: LifecycleHealthFailure) -> LifecycleState {
        .failed(message: failure.message)
    }

    private func finishPropertiesRequest(with state: LifecycleState) {
        machine = LifecycleStateMachine(state: state)
        activeRequest = nil
        activeRequestKind = nil
        switch state {
        case .awaitingApproval, .failed:
            retryAction = .status
        case .disabled:
            retryAction = .activation
        default:
            retryAction = nil
        }
        initialStatusResolved = true
    }

    private func transition(_ event: LifecycleEvent) {
        do {
            let newState = try machine.apply(event)
            logger.notice("Lifecycle entered \(String(describing: newState), privacy: .public)")
        } catch {
            machine = LifecycleStateMachine(state: .failed(message: "An internal lifecycle transition failed. Traffic is not claimed as filtered."))
            retryAction = .status
            logger.error("Rejected lifecycle transition")
        }
    }
}

extension FilterLifecycleController: OSSystemExtensionRequestDelegate {
    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        let current = ExtensionIdentity(
            bundleIdentifier: existing.bundleIdentifier,
            shortVersion: existing.bundleShortVersion,
            buildVersion: existing.bundleVersion
        )
        let incoming = ExtensionIdentity(
            bundleIdentifier: ext.bundleIdentifier,
            shortVersion: ext.bundleShortVersion,
            buildVersion: ext.bundleVersion
        )
        guard permitsReplacement(existing: current, incoming: incoming) else {
            Task { @MainActor [weak self] in
                self?.retryAction = .activation
                self?.transition(.fail(
                    "Abyss refused to replace the installed network filter with an older or mismatched copy."
                ))
            }
            return .cancel
        }
        Task { @MainActor [weak self] in
            self?.transition(.beginReplacement)
        }
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor [weak self] in
            self?.retryAction = .status
            self?.transition(.approvalRequired)
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let kind = self.activeRequestKind
            if kind != .properties {
                self.activeRequest = nil
                self.activeRequestKind = nil
            }
            if result == .willCompleteAfterReboot {
                self.retryAction = nil
                switch kind {
                case .activation:
                    self.transition(.fail(
                        "macOS will finish installing the network filter after a restart. Restart this Mac, then reopen Abyss."
                    ))
                case .deactivation:
                    self.transition(.fail(
                        "macOS will finish removing the network filter after a restart. Restart this Mac before reinstalling Abyss."
                    ))
                case .properties:
                    self.finishPropertiesRequest(with: .failed(
                        message: "macOS deferred the installed-state query until after a restart."
                    ))
                case nil:
                    break
                }
                return
            }
            switch kind {
            case .properties:
                break
            case .deactivation:
                self.retryAction = nil
                self.transition(.uninstallSucceeded)
            case .activation:
                self.retryAction = nil
                self.transition(.activationSucceeded)
                Task { await self.enableFilter() }
            case nil:
                break
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let value = error as NSError
        Task { @MainActor [weak self] in
            guard let self else { return }
            let kind = self.activeRequestKind
            self.activeRequest = nil
            self.activeRequestKind = nil
            if kind == .properties {
                self.initialStatusResolved = true
                self.retryAction = .status
                self.machine = LifecycleStateMachine(
                    state: .failed(message: "Installed-state query failed with \(self.sanitized(error)).")
                )
                return
            }
            if value.domain == OSSystemExtensionErrorDomain,
               value.code == OSSystemExtensionError.authorizationRequired.rawValue {
                self.retryAction = .activation
                self.transition(.permissionDenied("macOS did not authorize the extension. Approve Abyss in System Settings, then try again."))
            } else {
                self.retryAction = kind == .activation ? .activation : .status
                self.transition(.fail("System extension setup failed with \(value.domain) (\(value.code)). Traffic remains unclaimed."))
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        let observations = properties.map {
            InstalledExtensionObservation(
                identity: ExtensionIdentity(
                    bundleIdentifier: $0.bundleIdentifier,
                    shortVersion: $0.bundleShortVersion,
                    buildVersion: $0.bundleVersion
                ),
                enabled: $0.isEnabled,
                awaitingApproval: $0.isAwaitingUserApproval,
                uninstalling: $0.isUninstalling
            )
        }
        Task { @MainActor [weak self] in
            guard let self, self.activeRequestKind == .properties else { return }
            let state = await self.reconciledState(for: observations)
            self.finishPropertiesRequest(with: state)
        }
    }
}
