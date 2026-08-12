import Foundation

extension PolicyRuntime {
    func beginConfigurationReset(
        targetLineageID: UUID,
        connectionID: UUID,
        leaseID: UUID
    ) async throws {
        try requireController(
            connectionID: connectionID,
            leaseID: leaseID,
            allowConfigurationReset: true
        )
        guard let controller, let store, let tombstones, let transfer else {
            throw PolicyRuntimeError.persistenceUnavailable
        }
        if case .configurationReset(let existingTarget) = controller.access,
           existingTarget != targetLineageID {
            throw PolicyRuntimeError.lineageMismatch
        }
        await transfer.abort()
        try await store.beginConfigurationReset(
            uid: controller.uid,
            targetLineageID: targetLineageID
        )
        self.controller?.access = .configurationReset(targetLineageID: targetLineageID)
        prompts.deactivate(controllerLeaseID: controller.leaseID)
        preparedPolicy = nil
        persistedTuple = nil
        activeTuple = nil
        activePolicy.store(nil)
        persistenceState.activePolicyChanged(false)
        reloads.publish(nil)
        expiryTask?.cancel()
        expiryTask = nil
        try await tombstones.erase()
        try await store.erasePolicyArtifactsForConfigurationReset(
            uid: controller.uid,
            targetLineageID: targetLineageID
        )
    }
}
