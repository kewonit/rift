import RiftCore

/// The words for each mode. The names describe what happens to a connection
/// with no rule, so someone can predict a mode without learning its meaning.
extension OperationMode {
    public static let choices: [OperationMode] = [.silentAllow, .alert, .silentDeny, .filterOff]

    public var displayName: String {
        switch self {
        case .alert: "Ask Me"
        case .silentAllow: "Allow and Watch"
        case .silentDeny: "Block Unless Allowed"
        case .filterOff: "Pause Rules"
        case .degradedFallback: "Unknown"
        }
    }

    public var summary: String {
        switch self {
        case .alert: "Ask about new connections with no rule."
        case .silentAllow: "Allow new connections unless a rule blocks them."
        case .silentDeny: "Block new connections unless a rule allows them."
        case .filterOff: "Allow everything and turn your rules off."
        case .degradedFallback: "Rift can’t confirm how connections are handled."
        }
    }

    public var needsConfirmation: Bool { self == .silentDeny || self == .filterOff }

    public var confirmationTitle: String {
        self == .filterOff ? "Pause your rules?" : "Block everything without an allow rule?"
    }

    public var confirmationMessage: String {
        self == .filterOff
            ? "Rift will allow all connections and stop applying your rules. You’ll still see activity."
            : "Rift will block every connection that no rule allows. Apps without an allow rule lose network access."
    }

    /// What happens to connections while Rift isn't running. The filter keeps
    /// working, but it can't ask anyone.
    public var quitMessage: String {
        switch self {
        case .alert:
            "Your rules stay active, but Rift can’t ask while it’s closed, so connections with no rule are allowed until you open it again."
        case .silentDeny:
            "Your rules stay active, and connections with no rule stay blocked. Activity may have gaps until you open Rift again."
        case .filterOff:
            "All connections stay allowed and your rules stay off until you change the mode."
        case .silentAllow, .degradedFallback:
            "Your rules stay active, and connections with no rule are allowed as usual. Activity may have gaps until you open Rift again."
        }
    }
}
