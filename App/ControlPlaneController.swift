import RiftCore
import RiftControl
import RiftIPC
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class ControlPlaneController {
    static let minimalFlowLimit = 10
#if DEBUG
    enum RuntimeMode: Equatable {
        case live
        case uiFixture
    }
#endif

    enum State: Equatable {
        case idle
        case databaseReady
        case connected(ProviderReadiness)
        case integrationUnavailable
        case failed
    }
    private(set) var state: State = .idle
    private(set) var lastHandshake: HandshakeState?
    private(set) var desiredPolicyTuple: PolicyTuple?
    private(set) var activePolicyTuple: PolicyTuple?
    private(set) var repository: PolicyRepository?
    private(set) var pendingPrompts: [PromptRequest] = []
    private(set) var lostEventCount: UInt64 = 0
    private(set) var activityRevision: UInt64 = 0
    private(set) var visualActivityRevision: UInt64 = 0
    var currentMode: OperationMode = .silentAllow
    @ObservationIgnored var recentDenyUntil: Date?
    var recentDenyVisible = false
    var persistentHistoryEnabled = false
    private(set) var historyRecovery: HistoryDatabaseRecovery?
    private(set) var configurationRecovery: ConfigurationDatabaseRecovery?
    private(set) var startupIssue: String?
    var configurationRecoveryRequired = false
    var configurationDatabaseURL: URL?
    var supportDirectoryURL: URL?
    var backups: DailyConfigurationBackup?
    var history: HistoryRepository?
    @ObservationIgnored var historyDatabaseURL: URL?
    var pendingRestoreBackupURL: URL?
    var transientHistory = TransientHistoryBuffer(maximumFlows: ControlPlaneController.minimalFlowLimit)
    @ObservationIgnored var monitorIsVisible = false
    @ObservationIgnored var visibleMonitorCount = 0
    @ObservationIgnored var visibleMenuCount = 0
    @ObservationIgnored var supportsActivitySubscriptions = false
    @ObservationIgnored var desiredActivitySubscription = ActivitySubscription(mode: .off)
    @ObservationIgnored var appliedActivitySubscription: ActivitySubscription?
    @ObservationIgnored var activitySubscriptionTask: Task<Void, Never>?
    @ObservationIgnored var activityDrain = VisualRefreshCoordinator()
    @ObservationIgnored var recentActivity: RecentActivitySnapshot?
    @ObservationIgnored var recentActivityRows: [MonitorEventRow] = []
    @ObservationIgnored var activityExpiryTask: Task<Void, Never>?
    @ObservationIgnored var attentionDrainRunning = false
    @ObservationIgnored var attentionDrainPending = false
    @ObservationIgnored var promptResyncPending = false
    @ObservationIgnored var activityConnectionGeneration: UInt64 = 0
    @ObservationIgnored private let visualActivityUpdates = VisualRefreshCoordinator()
    @ObservationIgnored let monitorCoverageCache = MonitorCoverageCache()
#if DEBUG
    private let runtimeMode: RuntimeMode
#endif
    @ObservationIgnored lazy var notifications = NotificationRouter()
    @ObservationIgnored private lazy var liveClient = FilterControlClient()
    @ObservationIgnored private lazy var liveCLITransfers = CLITransferStore()
    @ObservationIgnored private var connectionHooksInstalled = false
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectState = ControlPlaneReconnectState()
    @ObservationIgnored private var runtimeHandshakeRefresh = RuntimeHandshakeRefreshState()
    @ObservationIgnored var authenticatedRootHighWater: AuthenticatedRootHighWater?
    @ObservationIgnored private var lossRuntimeInstanceID: UUID?
    @ObservationIgnored private var lossHighWater: UInt64 = 0
    var recentDenyTask: Task<Void, Never>?

    var client: FilterControlClient {
#if DEBUG
        precondition(!isUIFixture, "The UI fixture cannot create a filter-control client.")
#endif
        return liveClient
    }

    var cliTransfers: CLITransferStore {
#if DEBUG
        precondition(!isUIFixture, "The UI fixture cannot create CLI transfer state.")
#endif
        return liveCLITransfers
    }

    var isUIFixture: Bool {
#if DEBUG
        runtimeMode == .uiFixture
#else
        false
#endif
    }

    var isMinimalActivity: Bool { !isUIFixture && !persistentHistoryEnabled }

#if DEBUG
    init(runtimeMode: RuntimeMode = .live) {
        self.runtimeMode = runtimeMode
    }
#else
    init() {}
#endif

#if DEBUG
    var fixtureTask: Task<Void, Never>?
    var fixtureRuleActions: [String: FilterAction] = [:]
#endif

    func start() async {
        guard state == .idle else { return }
#if DEBUG
        if isUIFixture {
            state = .connected(.ready)
            currentMode = .silentAllow
            return
        }
#endif
        do {
            guard let group = Bundle.main.object(
                forInfoDictionaryKey: "RiftAppGroupIdentifier"
            ) as? String,
                  let container = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: group
                  ) else {
                throw ControlPlaneControllerError.appGroupUnavailable
            }
            let support = container.appendingPathComponent("ControlPlane", isDirectory: true)
            let configurationURL = support.appendingPathComponent("config.sqlite")
            supportDirectoryURL = support
            configurationDatabaseURL = configurationURL
            let configurationResult = Result {
                try ConfigurationDatabase.open(at: configurationURL)
            }
            guard case .success(let database) = configurationResult else {
                configurationRecoveryRequired = true
                startupIssue = "The editable configuration database failed validation. Rift did not replace it; the last validated extension policy may still be active. Import a known-good configuration from Settings › Advanced to preserve the invalid database and recover safely."
                state = .failed
                await prepareConfigurationRecoveryConnection()
                return
            }
            repository = PolicyRepository(database: database)
            if let configuration = try await repository?.currentConfiguration() {
                currentMode = configuration.operationMode
            }
            let backupDirectory = support.appendingPathComponent("Backups", isDirectory: true)
            backups = DailyConfigurationBackup(database: database, directory: backupDirectory)
            if let recovery = try await repository?.pendingRestoreRecovery() {
                pendingRestoreBackupURL = backupDirectory.appendingPathComponent(
                    recovery.backupName, isDirectory: false
                )
            }
            let historyURL = support.appendingPathComponent("history.sqlite")
            historyDatabaseURL = historyURL
            let isNewHistory = !FileManager.default.fileExists(atPath: historyURL.path)
            let savedHistoryPreference = UserDefaults.standard.object(forKey: "persistentHistoryEnabled") as? Bool
            if savedHistoryPreference == false || (savedHistoryPreference == nil && isNewHistory) {
                UserDefaults.standard.set(false, forKey: "persistentHistoryEnabled")
            } else {
                persistentHistoryEnabled = savedHistoryPreference ?? true
                transientHistory = TransientHistoryBuffer()
                let historyOpenResult = Result {
                    try HistoryDatabase.openRecovering(
                        at: historyURL
                    )
                }
                if case .success(let historyResult) = historyOpenResult {
                    history = HistoryRepository(database: historyResult.database)
                    if isNewHistory {
                        try await history?.configure(enabled: persistentHistoryEnabled, retentionDays: 30, maximumFlows: 50_000)
                    }
                    persistentHistoryEnabled = try await history?.settings().enabled ?? false
                    UserDefaults.standard.set(persistentHistoryEnabled, forKey: "persistentHistoryEnabled")
                    if persistentHistoryEnabled {
                        transientHistory = TransientHistoryBuffer()
                        try await history?.markOpenFlowsAbandoned()
                    } else { history = nil }
                    historyRecovery = historyResult.recovery
                } else {
                    startupIssue = "Connection history could not be opened or safely quarantined. Rift did not delete it; filtering configuration remains separate."
                }
            }
            state = .databaseReady
            await installConnectionHooks()
            requestReconnect()
        } catch {
            state = .failed
        }
    }

    func requestReconnect() {
#if DEBUG
        guard !isUIFixture else { return }
#endif
        guard state != .idle,
              repository != nil || configurationRecoveryRequired,
              reconnectTask == nil,
              reconnectState.beginIfNeeded() else { return }
        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    func installConnectionHooks() async {
        guard !connectionHooksInstalled else { return }
        let relay = AppRelayHandler { [weak self] request in
            guard let self else { throw ControlPlaneControllerError.localConfigurationMissing }
            return try await self.handleCLIRequest(request)
        } runtimeSignal: { [weak self] in
            await self?.handleRuntimeSignal()
        } activitySignal: { [weak self] in
            await self?.scheduleActivityDrain()
        } attentionSignal: { [weak self] in
            await self?.drainRuntimeAttention()
        }
        await client.installAppRelay(relay)
        await client.installInvalidationHandler { [weak self] in
            await self?.filterConnectionInvalidated()
        }
        connectionHooksInstalled = true
    }

    private func runReconnectLoop() async {
        defer {
            reconnectState.finishAndReset()
            reconnectTask = nil
        }
        while !Task.isCancelled {
            do {
                try Task.checkCancellation()
                try await connectAndReconcile()
                return
            } catch is CancellationError {
                await client.invalidate()
                return
            } catch {
                await client.invalidate()
                if !configurationRecoveryRequired { state = .integrationUnavailable }
            }
            guard let delay = reconnectState.delayAfterFailureSeconds() else { return }
            do {
                try await Task.sleep(for: .seconds(Int64(delay)))
            } catch {
                return
            }
        }
    }

    private func connectAndReconcile() async throws {
        let connectionID = try await client.connect()
        let handshake = try await client.handshake()
        try await client.requireCurrentConnection(connectionID)
        lastHandshake = handshake
        activePolicyTuple = handshake.active
        authenticatedRootHighWater = nil
        if configurationRecoveryRequired { return }
        try await establishController(handshake: handshake)
        let current = try await client.handshake()
        try await client.requireCurrentConnection(connectionID)
        await refreshAuthenticatedRootHighWater(from: current)
        presentRuntimeHandshake(current)
#if DEBUG
        if !(await startFixtureDriverIfRequested()) { await resumeRuntimeCollection() }
#else
        await resumeRuntimeCollection()
#endif
    }

    private func filterConnectionInvalidated() {
        resetActivityConnection()
        lastHandshake = nil
        activePolicyTuple = nil
        pendingPrompts.removeAll()
        if !configurationRecoveryRequired { state = .integrationUnavailable }
        requestReconnect()
    }

    private func handleRuntimeSignal() async {
        let shouldRefresh = runtimeHandshakeRefresh.signal()
        presentRuntimeHandshake(nil)
        guard shouldRefresh else { return }

        var refreshFailed = false
        while true {
            do {
                let connectionID = try await client.connect()
                let handshake = try await client.handshake()
                try await client.requireCurrentConnection(connectionID)
                await refreshAuthenticatedRootHighWater(from: handshake)
                if runtimeHandshakeRefresh.complete(with: handshake) { continue }
                presentRuntimeHandshake(runtimeHandshakeRefresh.presentedHandshake)
                refreshFailed = false
                break
            } catch {
                if runtimeHandshakeRefresh.complete(with: nil) { continue }
                presentRuntimeHandshake(nil)
                refreshFailed = true
                break
            }
        }

        await resumeRuntimeCollection()
        if refreshFailed { requestReconnect() }
    }

    func requestRuntimeControlRefresh() {
        Task { [weak self] in await self?.handleRuntimeSignal() }
    }

    private func presentRuntimeHandshake(_ handshake: HandshakeState?) {
        if let handshake, lastHandshake?.providerEpoch != handshake.providerEpoch {
            clearRecentActivity()
        }
        lastHandshake = handshake
        supportsActivitySubscriptions = handshake?.protocolRange.maximum.supports(
            minimum: .activitySubscriptions
        ) ?? false
        activePolicyTuple = handshake?.active
        guard let handshake else {
            if !pendingPrompts.isEmpty { pendingPrompts.removeAll() }
            if !configurationRecoveryRequired { state = .integrationUnavailable }
            return
        }
        state = .connected(handshake.readiness)
        if let epoch = handshake.providerEpoch {
            if pendingPrompts.contains(where: { $0.providerEpoch != epoch }) {
                pendingPrompts.removeAll { $0.providerEpoch != epoch }
            }
        } else {
            if !pendingPrompts.isEmpty { pendingPrompts.removeAll() }
        }
    }

    func recordRuntimeLoss(_ highWater: UInt64) -> Bool {
        let runtimeID = lastHandshake?.runtimeInstanceID
        let increment = runtimeID == lossRuntimeInstanceID && highWater >= lossHighWater
            ? highWater - lossHighWater : highWater
        lossRuntimeInstanceID = runtimeID
        lossHighWater = highWater
        let (sum, overflow) = lostEventCount.addingReportingOverflow(increment)
        lostEventCount = overflow ? .max : sum
        return increment > 0
    }

    func recordRuntimeActivity(_ changed: Bool) {
        guard changed else { return }
        if activityRevision < .max { activityRevision += 1 }
        guard monitorIsVisible else { return }
        visualActivityUpdates.request { [weak self] in
            guard let self, monitorIsVisible else { return }
            if visualActivityRevision < .max { visualActivityRevision += 1 }
        }
    }

    func setVisualActivityVisible(_ visible: Bool) {
        if visible { visualActivityUpdates.setVisible(true) }
        else { visualActivityUpdates.stop() }
    }

    func mergeIncomingPrompts(_ incoming: [PromptRequest], now: Date) {
        guard !incoming.isEmpty || !pendingPrompts.isEmpty else { return }
        for prompt in incoming where prompt.deadline > now {
            pendingPrompts.removeAll {
                $0.nonce == prompt.nonce ||
                    ($0.providerEpoch == prompt.providerEpoch && $0.flowID == prompt.flowID)
            }
            pendingPrompts.append(prompt)
        }
        pendingPrompts.removeAll { $0.deadline <= now }
    }

    func retainActivePrompts(_ nonces: Set<UUID>) {
        if pendingPrompts.contains(where: { !nonces.contains($0.nonce) }) {
            pendingPrompts.removeAll { !nonces.contains($0.nonce) }
        }
    }

    func reconcilePendingPrompts(with batch: RuntimeEventBatch) {
        guard !pendingPrompts.isEmpty else { return }
        guard let epoch = batch.providerEpoch else {
            pendingPrompts.removeAll()
            return
        }
        let resolvedFlowIDs = Set(batch.events.lazy
            .filter { $0.providerEpoch == epoch && $0.kind == .decision }
            .map { $0.flow.flowID })
        pendingPrompts.removeAll {
            $0.providerEpoch != epoch || resolvedFlowIDs.contains($0.flowID)
        }
    }

    func installRecoveredConfiguration(
        _ result: ConfigurationDatabaseOpenResult, support: URL
    ) async throws {
        authenticatedRootHighWater = nil
        repository = PolicyRepository(database: result.database)
        let backupDirectory = support.appendingPathComponent("Backups", isDirectory: true)
        backups = DailyConfigurationBackup(database: result.database, directory: backupDirectory)
        historyDatabaseURL = support.appendingPathComponent("history.sqlite")
        if persistentHistoryEnabled {
            let opened = Result {
                try HistoryDatabase.openRecovering(at: support.appendingPathComponent("history.sqlite"))
            }
            if case .success(let result) = opened {
                history = HistoryRepository(database: result.database)
                persistentHistoryEnabled = try await history?.settings().enabled ?? false
                if persistentHistoryEnabled { try await history?.markOpenFlowsAbandoned() }
                historyRecovery = result.recovery
                startupIssue = nil
            } else {
                startupIssue = "Connection history is unavailable, but configuration recovery can continue. Rift did not delete the history database."
            }
        }
        configurationRecovery = result.recovery
        configurationRecoveryRequired = false
        state = .databaseReady
    }
    func finishConfigurationRecovery(_ value: HandshakeState) {
        lastHandshake = value; activePolicyTuple = value.active; state = .connected(value.readiness)
    }
    func markConfigurationRecoveryPending() { state = .integrationUnavailable }
    func recordSavedDesiredPolicy(_ tuple: PolicyTuple) { desiredPolicyTuple = tuple }
    func recordHandshake(_ handshake: HandshakeState) {
        lastHandshake = handshake; activePolicyTuple = handshake.active
    }
    func recordActivePolicy(_ tuple: PolicyTuple) { activePolicyTuple = tuple }

    func answerOnce(_ prompt: PromptRequest, action: FilterAction) async throws {
#if DEBUG
        if isUIFixture {
            if MonitorFixtureData.scenario == .alertDeliveryFailure {
                throw ControlPlaneSafetyError.stalePrompt
            }
            pendingPrompts.removeAll { $0.nonce == prompt.nonce }
            return
        }
#endif
        try await client.answerPrompt(PromptAnswer(
            nonce: prompt.nonce,
            providerEpoch: prompt.providerEpoch,
            lineageID: prompt.lineageID,
            generation: prompt.generation,
            action: action
        ))
        pendingPrompts.removeAll { $0.nonce == prompt.nonce }
    }
    func ruleRows(filter: RuleListFilter, search: String) async throws -> [RuleRowViewValue] {
#if DEBUG
        if isUIFixture { return MonitorFixtureData.ruleRows(filter: filter, search: search) }
#endif
        guard let repository,
              let draft = try await repository.currentConfiguration(),
              let desired = try await repository.newestDesiredPolicy() else { return [] }
        let usage = try await repository.ruleUsage(ruleIDs: Set(draft.rules.map(\.id)))
        return RuleWorkspaceQuery.rows(
            rules: draft.rules,
            state: desired.state,
            generation: desired.tuple.generation,
            filter: filter,
            search: search,
            usage: usage
        )
    }

    func removePendingPrompt(_ nonce: UUID) { pendingPrompts.removeAll { $0.nonce == nonce } }
    func markFailed() { state = .failed }
    func recordStartupIssue(_ message: String) { startupIssue = message }
    func recordHistoryRecovery(_ recovery: HistoryDatabaseRecovery?) { historyRecovery = recovery }

    func requestNotificationPermission() async throws -> Bool {
        try await notifications.requestPermission()
    }


}

enum ControlPlaneControllerError: Error {
    case appGroupUnavailable
    case missingProviderEpoch
    case localConfigurationMissing
}
