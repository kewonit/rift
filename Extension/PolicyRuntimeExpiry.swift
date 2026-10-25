import RiftCore
import RiftFilterRuntime
import RiftIPC
import Foundation

extension PolicyRuntime {
    func reconcileExpiryMetadata(
        afterSuccessfulPolicyLoadIn store: RootPolicyStore
    ) async -> ExpiryMetadata {
        guard let tombstones else { return .unavailable }
        return await ExpiryTombstoneReconciler.reconcileAfterSuccessfulPolicyLoad(
            policyStore: store,
            tombstoneStore: tombstones
        )
    }

    func loadedExpiryMetadata(_ metadata: ExpiryMetadata) -> ExpiryMetadata {
        switch metadata {
        case .available(let keys):
            return persistenceState.tombstonesLoaded(keys)
        case .unavailable:
            logger.error("Expiry tombstone reconciliation failed with a redacted storage error")
            return persistenceState.tombstonePersistenceFailed()
        }
    }

    func scheduleExpiry(for policy: RuntimePolicy?, epoch: UUID?) {
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

    func expireRules(epoch: UUID, tuple: PolicyTuple) async {
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
