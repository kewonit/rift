import Foundation
import RiftCore
import RiftIPC

/// The wording and choices of a connection alert.
public enum ConnectionAlertPresentation {
    /// An incoming alert has no remote address to show, so it never names one.
    public static func headline(
        application: String,
        destination: String,
        direction: TrafficDirection
    ) -> String {
        switch direction {
        case .incoming: String(localized: "Something wants to connect to \(application) on this Mac.", bundle: .module)
        default: String(localized: "\(application) wants to connect to \(destination).", bundle: .module)
        }
    }

    public static func moreWaitingLabel(_ count: Int) -> String? {
        count > 0 ? String(localized: "\(count) more waiting", bundle: .module) : nil
    }

    /// Whether One hour and Always can be chosen. A system process needs its
    /// confirmation first, so a visible choice is never quietly downgraded.
    /// A locked configuration takes no new rules, so an alert can still be
    /// answered, but only for this connection.
    public static func allowsLastingChoice(
        canCreateRule: Bool,
        needsSystemConfirmation: Bool,
        systemConfirmed: Bool,
        configurationLocked: Bool = false
    ) -> Bool {
        !configurationLocked && canCreateRule && (!needsSystemConfirmation || systemConfirmed)
    }

    public static func lastingChoiceHint(
        hasIdentity: Bool,
        hasEndpoint: Bool,
        configurationLocked: Bool = false
    ) -> String? {
        if configurationLocked { return String(localized: "Rift’s configuration is locked, so you can only answer once.", bundle: .module) }
        if !hasIdentity { return String(localized: "Rift couldn’t identify this app, so you can only answer once.", bundle: .module) }
        if !hasEndpoint { return String(localized: "Rift doesn’t know the destination, so you can only answer once.", bundle: .module) }
        return nil
    }
}
