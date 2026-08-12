import Foundation

public enum LifecycleState: Sendable, Equatable, Codable {
    case notInstalled
    case activating
    case awaitingApproval
    case active
    case savingFilterConfiguration
    case enabled
    case denied(message: String)
    case disabled
    case stale
    case replacing
    case failed(message: String)
    case uninstalling

    public var isDegraded: Bool {
        switch self {
        case .denied, .disabled, .stale, .failed:
            true
        case .notInstalled, .activating, .awaitingApproval, .active,
                .savingFilterConfiguration, .enabled, .replacing, .uninstalling:
            false
        }
    }

    public var telemetryAvailable: Bool {
        switch self {
        case .enabled:
            true
        case .notInstalled, .activating, .awaitingApproval, .active,
                .savingFilterConfiguration, .denied, .disabled, .stale,
                .replacing, .failed, .uninstalling:
            false
        }
    }
}
