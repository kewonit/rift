import Foundation
import RiftCore

/// The words in Rift's notifications. They only claim what's known: a
/// notification can come from a block or an undecided connection as well as a
/// rule, so it never says a rule matched.
public enum NotificationCopy {
    public static func title(action: FilterAction) -> String {
        action == .deny
            ? String(localized: "Rift blocked a connection", bundle: .module)
            : String(localized: "Rift allowed a connection with no rule", bundle: .module)
    }

    public static func body(destination: String?) -> String {
        destination.map { String(localized: "Destination: \($0)", bundle: .module) }
            ?? String(localized: "Click to see it in Rift.", bundle: .module)
    }

    public static func summary(count: UInt64) -> String {
        String(localized: "\(count) more notifications were combined into this summary.", bundle: .module)
    }
}
