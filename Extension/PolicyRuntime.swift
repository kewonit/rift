import AbyssCore
import AbyssFilterRuntime
import AbyssIPC
import Foundation
import OSLog

actor PolicyRuntime {
    nonisolated let activePolicy = ActivePolicyReference()

    struct ControllerLease: Sendable {
        enum Access: Sendable, Equatable {
            case full
            case verifiedUninstallRecovery
            case configurationReset(targetLineageID: UUID)
        }

        let connectionID: UUID
        let uid: UInt32
        let auditSessionID: Int32
        let leaseID: UUID
        var access: Access
    }

    private let logger = Logger(subsystem: "io.abyss.firewall.filter", category: "runtime")
    private let runtimeInstanceID = UUID()
    let store: RootPolicyStore?
    let transfer: SnapshotTransferCoordinator?
    let tombstones: ExpiryTombstoneStore?
    let prompts: PromptQueue
    private let events: RuntimeEventRing
    private let notifications: EphemeralNotificationQueue
    let reloads: PolicyReloadSignal
    var providerEpoch: UUID?
    var preparedPolicy: RuntimePolicy?
    var persistedTuple: PolicyTuple?
    var activeTuple: PolicyTuple?
    var persistenceState = ProviderPersistenceState()
    var controller: ControllerLease?
    var expiryTask: Task<Void, Never>?

    init(
        rootURL: URL?,
        prompts: PromptQueue,
        events: RuntimeEventRing,
        notifications: EphemeralNotificationQueue,
        reloads: PolicyReloadSignal
    ) {
        let bootstrap = RuntimePersistenceBootstrap(rootURL: rootURL)
        self.store = bootstrap.rootStore
        self.transfer = bootstrap.rootStore.map(SnapshotTransferCoordinator.init(store:))
        self.tombstones = bootstrap.tombstoneStore
        self.prompts = prompts
        self.events = events
        self.notifications = notifications
        self.reloads = reloads
    }

    func prepareProviderStart() async -> UUID {
        let epoch = UUID()
        providerEpoch = epoch
        persistenceState.beginProviderStart(
            rootPersistenceAvailable: store != nil,
            tombstonePersistenceAvailable: tombstones != nil
        )
        preparedPolicy = nil
        activeTuple = nil
        activePolicy.store(nil)
        reloads.publish(nil)
        guard let store else {
            persistedTuple = nil
            persistenceState.rootPersistenceFailed()
            logger.error("Runtime bootstrap is degraded by a redacted storage error")
            return epoch
        }
        do {
            _ = try await store.initializeIfNeeded()
            guard providerEpoch == epoch else { return epoch }
            persistenceState.rootPersistenceSucceeded()
            let recovered = try await store.recoverNewest()
            guard providerEpoch == epoch else { return epoch }
            persistedTuple = recovered.tuple
            let recoveredExpiry = await reconcileExpiryMetadata(
                afterSuccessfulPolicyLoadIn: store
            )
            guard providerEpoch == epoch else { return epoch }
            let expiry = loadedExpiryMetadata(recoveredExpiry)
            preparedPolicy = RuntimePolicy(recovered: recovered, expiryMetadata: expiry)
        } catch RootPolicyStoreError.noValidPolicy {
            persistedTuple = nil
        } catch RootPolicyStoreError.mutationLocked {
            persistedTuple = nil
        } catch {
            guard providerEpoch == epoch else { return epoch }
            persistedTuple = nil
            persistenceState.rootPersistenceFailed()
            logger.error("Root policy recovery failed with a redacted storage error")
        }
        return epoch
    }

    func completeProviderStart(epoch: UUID, settingsSucceeded: Bool) -> ProviderReadiness {
        guard providerEpoch == epoch else { return persistenceState.readiness }
        guard settingsSucceeded else {
            preparedPolicy = nil
            activePolicy.store(nil)
            activeTuple = nil
            let readiness = persistenceState.completeProviderStart(
                settingsSucceeded: false,
                hasActivePolicy: false
            )
            reloads.publish(nil)
            return readiness
        }
        if let preparedPolicy {
            activePolicy.store(preparedPolicy)
            activeTuple = preparedPolicy.tuple
        }
        preparedPolicy = nil
        let readiness = persistenceState.completeProviderStart(
            settingsSucceeded: true,
            hasActivePolicy: activeTuple != nil
        )
        if let controller, controller.access == .full {
            prompts.activate(controllerLeaseID: controller.leaseID, providerEpoch: epoch)
        }
        events.activate(providerEpoch: epoch)
        reloads.publish(activePolicy.load())
        scheduleExpiry(for: activePolicy.load(), epoch: epoch)
        logger.notice("Provider epoch completed with readiness \(readiness.rawValue, privacy: .public)")
        return readiness
    }

    func stopProvider(epoch: UUID?) {
        guard let epoch, providerEpoch == epoch else { return }
        providerEpoch = nil
        events.deactivate(providerEpoch: epoch)
        expiryTask?.cancel()
        expiryTask = nil
        if let controller, controller.access == .full {
            prompts.activate(controllerLeaseID: controller.leaseID, providerEpoch: nil)
        }
        preparedPolicy = nil
        activeTuple = nil
        activePolicy.store(nil)
        reloads.publish(nil)
        persistenceState.stopProvider()
    }

    func handshake(
        for connectionID: UUID,
        uid: UInt32,
        mayDisclosePolicy sessionMayDisclosePolicy: Bool
    ) async -> HandshakeState {
        var highWater: UInt64 = 0
        var disclosePolicy = false
        var boundLineageID: UUID?
        var configurationResetLineageID: UUID?
        if let store {
            do {
                switch try await store.initializeIfNeeded() {
                case .owned(let ownerUID, let lineageID, let generation):
                    disclosePolicy = ownerUID == uid && sessionMayDisclosePolicy
                    highWater = disclosePolicy ? generation : 0
                    boundLineageID = disclosePolicy ? lineageID : nil
                case .unclaimed:
                    disclosePolicy = sessionMayDisclosePolicy
                case .replacingConfiguration(let oldUID, let targetLineageID):
                    disclosePolicy = oldUID == uid && sessionMayDisclosePolicy
                    boundLineageID = disclosePolicy ? targetLineageID : nil
                    configurationResetLineageID = disclosePolicy ? targetLineageID : nil
                case .resetting:
                    break
                }
            } catch {
                disclosePolicy = false
            }
        }
        return HandshakeState(
            runtimeInstanceID: runtimeInstanceID,
            providerEpoch: providerEpoch,
            readiness: persistenceState.readiness,
            protocolRange: ProtocolRange(minimum: .baseline, maximum: .current),
            snapshotSchemaRange: 1...CompiledPolicyPayload.currentSchemaVersion,
            acceptedGenerationHighWater: highWater,
            boundLineageID: boundLineageID,
            configurationResetLineageID: configurationResetLineageID,
            persisted: disclosePolicy ? persistedTuple : nil,
            active: disclosePolicy ? activeTuple : nil,
            controllerLeaseID: disclosePolicy && controller?.connectionID == connectionID
                ? controller?.leaseID : nil
        )
    }

    func claimController(
        connectionID: UUID,
        uid: UInt32,
        auditSessionID: Int32,
        lineageID: UUID,
        isCurrentConsoleUser: Bool
    ) async throws -> UUID {
        guard isCurrentConsoleUser else { throw PolicyRuntimeError.notCurrentConsoleSession }
        if let controller {
            guard controller.connectionID == connectionID else { throw PolicyRuntimeError.controllerBusy }
            if case .configurationReset(let targetLineageID) = controller.access,
               targetLineageID != lineageID {
                throw PolicyRuntimeError.lineageMismatch
            }
            return controller.leaseID
        }
        guard let store else { throw PolicyRuntimeError.persistenceUnavailable }
        let authorization: ControllerClaimAuthorization
        do {
            authorization = try ControllerClaimGate.authorize(
                ownership: try await store.initializeIfNeeded(),
                uid: uid,
                lineageID: lineageID,
                providerEpoch: providerEpoch,
                persistenceState: persistenceState
            )
        } catch let error as ControllerClaimAuthorizationError {
            throw PolicyRuntimeError(error)
        }
        switch authorization {
        case .claimFirstOwner:
            try await store.claim(uid: uid, lineageID: lineageID)
        case .reconnectExistingOwner:
            break
        case .resumeVerifiedUninstall:
            break
        case .resumeConfigurationReset:
            break
        }
        let access: ControllerLease.Access
        switch authorization {
        case .claimFirstOwner, .reconnectExistingOwner:
            access = .full
        case .resumeVerifiedUninstall:
            access = .verifiedUninstallRecovery
        case .resumeConfigurationReset(let targetLineageID):
            access = .configurationReset(targetLineageID: targetLineageID)
        }
        let lease = ControllerLease(
            connectionID: connectionID,
            uid: uid,
            auditSessionID: auditSessionID,
            leaseID: UUID(),
            access: access
        )
        controller = lease
        if lease.access == .full {
            prompts.activate(controllerLeaseID: lease.leaseID, providerEpoch: providerEpoch)
        }
        return lease.leaseID
    }

    func beginTransfer(
        _ header: SnapshotTransferBegin,
        connectionID: UUID,
        leaseID: UUID,
        now: Date
    ) async throws {
        try requireController(
            connectionID: connectionID,
            leaseID: leaseID,
            allowConfigurationReset: true
        )
        guard let transfer else { throw PolicyRuntimeError.persistenceUnavailable }
        try await transfer.begin(header, now: now)
    }

    func appendTransfer(
        _ chunk: SnapshotChunk,
        connectionID: UUID,
        leaseID: UUID,
        now: Date
    ) async throws {
        try requireController(
            connectionID: connectionID,
            leaseID: leaseID,
            allowConfigurationReset: true
        )
        guard let transfer else { throw PolicyRuntimeError.persistenceUnavailable }
        try await transfer.append(offset: chunk.offset, chunk: chunk.bytes, now: now)
    }

    func finishTransfer(
        connectionID: UUID,
        leaseID: UUID,
        now: Date
    ) async throws -> SnapshotFinishResult {
        try requireController(
            connectionID: connectionID,
            leaseID: leaseID,
            allowConfigurationReset: true
        )
        guard let transfer, let store else { throw PolicyRuntimeError.persistenceUnavailable }
        let recovered = try await transfer.finish(now: now)
        if case .configurationReset(let targetLineageID) = controller?.access {
            guard recovered.tuple.lineageID == targetLineageID,
                  recovered.tuple.generation == 1 else {
                throw PolicyRuntimeError.lineageMismatch
            }
            controller?.access = .full
            if let controller {
                prompts.activate(
                    controllerLeaseID: controller.leaseID,
                    providerEpoch: providerEpoch
                )
            }
        }
        persistedTuple = recovered.tuple
        let recoveredExpiry = await reconcileExpiryMetadata(
            afterSuccessfulPolicyLoadIn: store
        )
        if let epoch = providerEpoch, persistenceState.canActivatePolicy {
            guard providerEpoch == epoch, persistenceState.canActivatePolicy else {
                return SnapshotFinishResult(
                    disposition: .persisted,
                    tuple: recovered.tuple,
                    providerEpoch: nil
                )
            }
            persistenceState.rootPersistenceSucceeded()
            let expiry = loadedExpiryMetadata(recoveredExpiry)
            let policy = RuntimePolicy(recovered: recovered, expiryMetadata: expiry)
            activePolicy.store(policy)
            activeTuple = policy.tuple
            persistenceState.activePolicyChanged(true)
            reloads.publish(policy)
            scheduleExpiry(for: policy, epoch: providerEpoch)
            return SnapshotFinishResult(
                disposition: .active,
                tuple: recovered.tuple,
                providerEpoch: epoch
            )
        }
        return SnapshotFinishResult(
            disposition: .persisted,
            tuple: recovered.tuple,
            providerEpoch: nil
        )
    }

    func abortTransfer(connectionID: UUID, leaseID: UUID) async throws {
        try requireController(
            connectionID: connectionID,
            leaseID: leaseID,
            allowConfigurationReset: true
        )
        guard let transfer else { throw PolicyRuntimeError.persistenceUnavailable }
        await transfer.abort()
    }

    func drainPrompts(connectionID: UUID, leaseID: UUID) throws -> [PromptRequest] {
        try requireController(connectionID: connectionID, leaseID: leaseID)
        return try prompts.drain(controllerLeaseID: leaseID)
    }

    func answerPrompt(
        _ answer: PromptAnswer,
        connectionID: UUID,
        leaseID: UUID
    ) throws {
        try requireController(connectionID: connectionID, leaseID: leaseID)
        try prompts.answer(answer, controllerLeaseID: leaseID)
    }

    func drainEvents(connectionID: UUID, leaseID: UUID) throws -> RuntimeEventBatch {
        try requireController(connectionID: connectionID, leaseID: leaseID)
        return events.drain()
    }

    func drainNotifications(connectionID: UUID, leaseID: UUID) throws -> [EphemeralNotificationEvent] {
        try requireController(connectionID: connectionID, leaseID: leaseID)
        return notifications.drain(now: Date())
    }

    func prepareVerifiedUninstall(connectionID: UUID, leaseID: UUID) async throws {
        try requireController(
            connectionID: connectionID,
            leaseID: leaseID,
            allowVerifiedUninstallRecovery: true,
            allowConfigurationReset: true
        )
        guard let controller else { throw PolicyRuntimeError.invalidControllerLease }
        guard let store, let tombstones else { throw PolicyRuntimeError.persistenceUnavailable }
        self.controller?.access = .verifiedUninstallRecovery
        prompts.deactivate(controllerLeaseID: controller.leaseID)
        try await store.beginVerifiedUninstall(uid: controller.uid)
        activePolicy.store(nil)
        persistedTuple = nil
        activeTuple = nil
        persistenceState.activePolicyChanged(false)
        reloads.publish(nil)
        try await tombstones.erase()
        try await store.erasePolicyArtifactsForVerifiedUninstall(uid: controller.uid)
        try await store.finishVerifiedUninstall(uid: controller.uid)
    }

    func connectionInvalidated(_ connectionID: UUID) async {
        guard let controller, controller.connectionID == connectionID else { return }
        prompts.deactivate(controllerLeaseID: controller.leaseID)
        self.controller = nil
        if let transfer { await transfer.abort() }
    }

    func requireController(
        connectionID: UUID,
        leaseID: UUID,
        allowVerifiedUninstallRecovery: Bool = false,
        allowConfigurationReset: Bool = false
    ) throws {
        guard let controller,
              controller.connectionID == connectionID,
              controller.leaseID == leaseID else { throw PolicyRuntimeError.invalidControllerLease }
        switch controller.access {
        case .full:
            return
        case .verifiedUninstallRecovery where allowVerifiedUninstallRecovery:
            return
        case .configurationReset where allowConfigurationReset:
            return
        default:
            throw PolicyRuntimeError.resetInProgress
        }
    }

    private func reconcileExpiryMetadata(
        afterSuccessfulPolicyLoadIn store: RootPolicyStore
    ) async -> ExpiryMetadata {
        guard let tombstones else { return .unavailable }
        return await ExpiryTombstoneReconciler.reconcileAfterSuccessfulPolicyLoad(
            policyStore: store,
            tombstoneStore: tombstones
        )
    }

    private func loadedExpiryMetadata(_ metadata: ExpiryMetadata) -> ExpiryMetadata {
        switch metadata {
        case .available(let keys):
            return persistenceState.tombstonesLoaded(keys)
        case .unavailable:
            logger.error("Expiry tombstone reconciliation failed with a redacted storage error")
            return persistenceState.tombstonePersistenceFailed()
        }
    }

    private func scheduleExpiry(for policy: RuntimePolicy?, epoch: UUID?) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let policy, let epoch, let deadline = policy.nextExpiry(after: Date()) else { return }
        let nanoseconds = UInt64(
            min(max(0, deadline.timeIntervalSinceNow), TimeInterval(UInt64.max / 1_000_000_000))
                * 1_000_000_000
        )
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self?.expireRules(epoch: epoch, tuple: policy.tuple)
        }
    }

    private func expireRules(epoch: UUID, tuple: PolicyTuple) async {
        guard providerEpoch == epoch, activeTuple == tuple, let policy = activePolicy.load() else { return }
        let additions = policy.expiryKeys(dueAt: Date()).subtracting(policy.recordedExpiryKeys)
        guard !additions.isEmpty else {
            scheduleExpiry(for: policy, epoch: epoch)
            return
        }
        let persistedKeys: Set<ExpiredRuleKey>?
        if let tombstones {
            do {
                persistedKeys = try await tombstones.record(additions)
            } catch {
                persistedKeys = nil
            }
        } else {
            persistedKeys = nil
        }
        guard providerEpoch == epoch, activeTuple == tuple,
              activePolicy.load()?.tuple == tuple else { return }
        let expiry: ExpiryMetadata
        if let persistedKeys {
            expiry = persistenceState.tombstonesPersisted(persistedKeys)
        } else {
            expiry = persistenceState.tombstonePersistenceFailed()
            logger.error("Expiry tombstone persistence failed with a redacted storage error")
        }
        let updated = policy.replacingExpiryMetadata(expiry)
        activePolicy.store(updated)
        reloads.publish(updated)
        scheduleExpiry(for: updated, epoch: epoch)
    }
}
