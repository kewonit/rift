import Foundation
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

    /// riftctl prints this too, so it's in English while `RiftLocale.english` is set.
    var message: String {
        let base: String
        let backupFailed: Bool
        switch self {
        case .enforced(let failed):
            base = String(localized: "Saved and applied.", bundle: RiftLocale.mainBundle)
            backupFailed = failed
        case .savedPending(let failed):
            base = String(localized: "Saved. Waiting for the filter to apply it.", bundle: RiftLocale.mainBundle)
            backupFailed = failed
        case .persistedPendingProvider(let failed):
            base = String(localized: "Saved. The filter will apply it once it’s running.", bundle: RiftLocale.mainBundle)
            backupFailed = failed
        case .applyFailed(let failed):
            base = String(localized: "Saved, but the filter couldn’t apply it. Try again after Rift reconnects.", bundle: RiftLocale.mainBundle)
            backupFailed = failed
        }
        return backupFailed ? String(localized: "\(base) The automatic backup didn’t complete.", bundle: RiftLocale.mainBundle) : base
    }

    var requiresAttention: Bool {
        if case .enforced(backupFailed: false) = self { return false }
        return true
    }
}
