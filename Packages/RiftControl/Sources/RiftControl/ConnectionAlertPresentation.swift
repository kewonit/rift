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
        case .incoming: "Something wants to connect to \(application) on this Mac."
        default: "\(application) wants to connect to \(destination)."
        }
    }

    public static func moreWaitingLabel(_ count: Int) -> String? {
        count > 0 ? "\(count) more waiting" : nil
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
        if configurationLocked { return "Rift’s configuration is locked, so you can only answer once." }
        if !hasIdentity { return "Rift couldn’t identify this app, so you can only answer once." }
        if !hasEndpoint { return "Rift doesn’t know the destination, so you can only answer once." }
        return nil
    }
}
