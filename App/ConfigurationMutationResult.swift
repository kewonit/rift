import RiftControl
import RiftCore

enum ConfigurationMutationResult: Sendable, Equatable {
    case enforced(backupFailed: Bool)
    case savedPending(backupFailed: Bool)
    case persistedPendingProvider(backupFailed: Bool)
    case applyFailed(backupFailed: Bool)

    init(state: PolicyOutboxState, backupFailed: Bool) {
        switch state {
        case .enforced: self = .enforced(backupFailed: backupFailed)
        case .savedPendingEnforcement: self = .savedPending(backupFailed: backupFailed)
        case .persistedPendingProvider:
            self = .persistedPendingProvider(backupFailed: backupFailed)
        case .applyFailed: self = .applyFailed(backupFailed: backupFailed)
        }
    }

    var message: String {
        let base: String
        let backupFailed: Bool
        switch self {
        case .enforced(let failed):
            base = "Saved and applied."
            backupFailed = failed
        case .savedPending(let failed):
            base = "Saved. Waiting for the filter to apply it."
            backupFailed = failed
        case .persistedPendingProvider(let failed):
            base = "Saved. The filter will apply it once it’s running."
            backupFailed = failed
        case .applyFailed(let failed):
            base = "Saved, but the filter couldn’t apply it. Try again after Rift reconnects."
            backupFailed = failed
        }
        return backupFailed ? base + " The automatic backup didn’t complete." : base
    }

    var requiresAttention: Bool {
        if case .enforced(backupFailed: false) = self { return false }
        return true
    }
}
