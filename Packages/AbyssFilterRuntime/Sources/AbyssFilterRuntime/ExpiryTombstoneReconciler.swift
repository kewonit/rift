import AbyssCore

public enum ExpiryTombstoneReconciler {
    public static func reconcileAfterSuccessfulPolicyLoad(
        policyStore: RootPolicyStore,
        tombstoneStore: ExpiryTombstoneStore
    ) async -> ExpiryMetadata {
        do {
            let retained = try await policyStore.pruneExpiryTombstones(
                using: tombstoneStore
            )
            return .available(alreadyExpired: retained)
        } catch {
            return .unavailable
        }
    }
}
