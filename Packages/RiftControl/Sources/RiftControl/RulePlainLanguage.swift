import RiftCore

/// Describes rule changes in the words someone would use themselves.
public enum RulePlainLanguage {
    public static func change(
        action: FilterAction,
        application: String,
        destination: String,
        port: UInt16?,
        incoming: Bool = false
    ) -> String {
        let onPort = port.map { " on port \($0)" } ?? ""
        if incoming {
            let result = action == .deny ? "blocked" : "allowed"
            return "Incoming connections to \(application)\(onPort) are now \(result)."
        }
        return action == .deny
            ? "\(application) is now blocked from \(destination)\(onPort)."
            : "\(application) can now connect to \(destination)\(onPort)."
    }
}
