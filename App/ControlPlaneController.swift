import RiftCore
import RiftControl
import RiftIPC
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class ControlPlaneController {
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
    var currentMode: OperationMode = .silentAllow
    var recentDenyUntil: Date?
    private(set) var historyRecovery: HistoryDatabaseRecovery?
    private(set) var configurationRecovery: ConfigurationDatabaseRecovery?
    private(set) var startupIssue: String?
    var configurationRecoveryRequired = false
    var configurationDatabaseURL: URL?
    var supportDirectoryURL: URL?
    var backups: DailyConfigurationBackup?
    var history: HistoryRepository?
    var pendingRestoreBackupURL: URL?
    var transientHistory = TransientHistoryBuffer()
    @ObservationIgnored var monitorIsVisible = false
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
            let historyOpenResult = Result {
                try HistoryDatabase.openRecovering(
                    at: support.appendingPathComponent("history.sqlite")
                )
            }
            if case .success(let historyResult) = historyOpenResult {
                history = HistoryRepository(database: historyResult.database)
                try await history?.markOpenFlowsAbandoned()
                historyRecovery = historyResult.recovery
            } else {
                startupIssue = "Connection history could not be opened or safely quarantined. Rift did not delete it; filtering configuration remains separate."
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
        if !(await startFixtureDriverIfRequested()) { await drainRuntimeData() }
#else
        await drainRuntimeData()
#endif
    }

    private func filterConnectionInvalidated() {
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

        await drainRuntimeData()
        if refreshFailed { requestReconnect() }
    }

    private func presentRuntimeHandshake(_ handshake: HandshakeState?) {
        lastHandshake = handshake
        activePolicyTuple = handshake?.active
        guard let handshake else {
            pendingPrompts.removeAll()
            if !configurationRecoveryRequired { state = .integrationUnavailable }
            return
        }
        state = .connected(handshake.readiness)
        if let epoch = handshake.providerEpoch {
            pendingPrompts.removeAll { $0.providerEpoch != epoch }
        } else {
            pendingPrompts.removeAll()
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
        if changed, activityRevision < .max { activityRevision += 1 }
    }

    func mergeIncomingPrompts(_ incoming: [PromptRequest], now: Date) {
        for prompt in incoming where prompt.deadline > now {
            pendingPrompts.removeAll {
                $0.nonce == prompt.nonce ||
                    ($0.providerEpoch == prompt.providerEpoch && $0.flowID == prompt.flowID)
            }
            pendingPrompts.append(prompt)
        }
        pendingPrompts.removeAll { $0.deadline <= now }
    }

    func reconcilePendingPrompts(with batch: RuntimeEventBatch) {
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

    func reconcileNewest(lineageID: UUID) async throws {
        guard let repository,
              let desired = try await repository.newestDesiredPolicy() else { return }
        desiredPolicyTuple = desired.tuple
        let handshake = try await client.handshake()
        lastHandshake = handshake
        activePolicyTuple = handshake.active
        if handshake.active == desired.tuple, let epoch = handshake.providerEpoch {
            try await repository.markEnforced(
                desired.tuple,
                providerEpoch: epoch,
                at: Date()
            )
            try await repository.clearPendingRestoreRecovery(
                throughGeneration: desired.tuple.generation
            )
            pendingRestoreBackupURL = nil
            return
        }
        if handshake.persisted == desired.tuple, handshake.providerEpoch == nil {
            try await repository.markPersisted(desired.tuple, at: Date())
            return
        }
        _ = try await client.claimController(lineageID: lineageID)
        let result = try await client.apply(DesiredTransfer(
            tuple: desired.tuple,
            bytes: desired.artifact.bytes
        ))
        switch result.disposition {
        case .persisted, .idempotent:
            try await repository.markPersisted(result.tuple, at: Date())
        case .active:
            guard let epoch = result.providerEpoch else {
                throw ControlPlaneControllerError.missingProviderEpoch
            }
            try await repository.markEnforced(result.tuple, providerEpoch: epoch, at: Date())
            activePolicyTuple = result.tuple
            try await repository.clearPendingRestoreRecovery(
                throughGeneration: result.tuple.generation
            )
            pendingRestoreBackupURL = nil
        }
    }

    func installRecoveredConfiguration(
        _ result: ConfigurationDatabaseOpenResult, support: URL
    ) async throws {
        authenticatedRootHighWater = nil
        repository = PolicyRepository(database: result.database)
        let backupDirectory = support.appendingPathComponent("Backups", isDirectory: true)
        backups = DailyConfigurationBackup(database: result.database, directory: backupDirectory)
        let opened = Result {
            try HistoryDatabase.openRecovering(at: support.appendingPathComponent("history.sqlite"))
        }
        if case .success(let result) = opened {
            history = HistoryRepository(database: result.database)
            try await history?.markOpenFlowsAbandoned()
            historyRecovery = result.recovery
            startupIssue = nil
        } else {
            startupIssue = "Connection history is unavailable, but configuration recovery can continue. Rift did not delete the history database."
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

    func reconcileSavedPolicy(_ desired: DesiredPolicy, lineageID: UUID) async throws {
        desiredPolicyTuple = desired.tuple
        do {
            try await reconcileNewest(lineageID: lineageID)
        } catch {
            guard let repository else { throw error }
            try await repository.markApplyFailed(desired.tuple, at: Date())
            throw error
        }
    }
    func answerOnce(_ prompt: PromptRequest, action: FilterAction) async throws {
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

    func requestNotificationPermission() async throws -> Bool {
        try await notifications.requestPermission()
    }

    private func establishController(handshake: HandshakeState) async throws {
        guard let repository else { return }
        if let configuration = try await repository.currentConfiguration() {
            _ = try await client.claimController(lineageID: configuration.lineageID)
            try await reconcileNewest(lineageID: configuration.lineageID)
            return
        }
        let lineageID: UUID
        switch try ControlPlaneSafety.initialLineageResolution(handshake: handshake) {
        case .resume(let existingLineageID):
            lineageID = existingLineageID
        case .unclaimed:
            lineageID = UUID()
        }
        _ = try await client.claimController(lineageID: lineageID)
        let initial = PolicyConfigurationDraft(
            lineageID: lineageID,
            authorizedUID: getuid(),
            operationMode: .silentAllow,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: []
        )
        let desired = try await repository.save(
            initial,
            extensionHighWater: handshake.acceptedGenerationHighWater,
            commandKind: "initialPolicy",
            redactedSummary: "silentAllow",
            now: Date()
        )
        try await reconcileSavedPolicy(desired, lineageID: lineageID)
    }

}

private enum ControlPlaneControllerError: Error {
    case appGroupUnavailable
    case missingProviderEpoch
    case localConfigurationMissing
}
