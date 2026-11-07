import RiftCore

/// Describes rule changes in the words someone would use themselves.
public enum RulePlainLanguage {
    public static func change(
        action: FilterAction,
        application: String,
        destination: String,
        port: UInt16?,
        incoming: Bool = false,
        forOneHour: Bool = false,
        isPreview: Bool = false
    ) -> String {
        let onPort = port.map { " on port \($0)" } ?? ""
        let duration = forOneHour ? " for one hour" : ""
        if incoming {
            let result = action == .deny ? "blocked" : "allowed"
            let verb = isPreview ? "will be" : "are now"
            return "Incoming connections to \(application)\(onPort) \(verb) \(result)\(duration)."
        }
        let blocked = isPreview ? "will be blocked from" : "is now blocked from"
        let allowed = isPreview ? "will be able to connect to" : "can now connect to"
        return "\(application) \(action == .deny ? blocked : allowed) \(destination)\(onPort)\(duration)."
    }
}
