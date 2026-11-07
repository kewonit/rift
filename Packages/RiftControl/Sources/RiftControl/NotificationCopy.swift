import RiftCore

/// The words in Rift's notifications. They only claim what's known: a
/// notification can come from a block or an undecided connection as well as a
/// rule, so it never says a rule matched.
public enum NotificationCopy {
    public static func title(action: FilterAction) -> String {
        action == .deny ? "Rift blocked a connection" : "Rift allowed a connection with no rule"
    }

    public static func body(destination: String?) -> String {
        destination.map { "Destination: \($0)" } ?? "Click to see it in Rift."
    }

    public static func summary(count: UInt64) -> String {
        count == 1
            ? "1 more notification was combined into this summary."
            : "\(count) more notifications were combined into this summary."
    }
}
