import Foundation
import RiftCore

/// The words for each mode. The names describe what happens to a connection
/// with no rule, so someone can predict a mode without learning its meaning.
extension OperationMode {
    public static let choices: [OperationMode] = [.silentAllow, .alert, .silentDeny, .filterOff]

    public var displayName: String {
        switch self {
        case .alert: String(localized: "Ask Me", bundle: .module)
        case .silentAllow: String(localized: "Allow and Watch", bundle: .module)
        case .silentDeny: String(localized: "Block Unless Allowed", bundle: .module)
        case .filterOff: String(localized: "Pause Rules", bundle: .module)
        case .degradedFallback: String(localized: "Unknown", bundle: .module)
        }
    }

    public var summary: String {
        switch self {
        case .alert: String(localized: "Ask about new connections with no rule.", bundle: .module)
        case .silentAllow: String(localized: "Allow new connections unless a rule blocks them.", bundle: .module)
        case .silentDeny: String(localized: "Block new connections unless a rule allows them.", bundle: .module)
        case .filterOff: String(localized: "Allow everything and turn your rules off.", bundle: .module)
        case .degradedFallback: String(localized: "Rift can’t confirm how connections are handled.", bundle: .module)
        }
    }

    public var needsConfirmation: Bool { self == .silentDeny || self == .filterOff }

    public var confirmationTitle: String {
        self == .filterOff ? String(localized: "Pause your rules?", bundle: .module) : String(localized: "Block everything without an allow rule?", bundle: .module)
    }

    public var confirmationMessage: String {
        self == .filterOff
            ? String(localized: "Rift will allow all connections and stop applying your rules. You’ll still see activity.", bundle: .module)
            : String(localized: "Rift will block every connection that no rule allows. Apps without an allow rule lose network access. Rift filters TCP and UDP only, so other traffic, such as ping, isn’t blocked.", bundle: .module)
    }

    /// What happens to connections while Rift isn't running. The filter keeps
    /// working, but it can't ask anyone.
    public var quitMessage: String {
        switch self {
        case .alert:
            String(localized: "Your rules stay active, but Rift can’t ask while it’s closed, so connections with no rule are allowed until you open it again.", bundle: .module)
        case .silentDeny:
            String(localized: "Your rules stay active, and connections with no rule stay blocked. Activity may have gaps until you open Rift again.", bundle: .module)
        case .filterOff:
            String(localized: "All connections stay allowed and your rules stay off until you change the mode.", bundle: .module)
        case .silentAllow, .degradedFallback:
            String(localized: "Your rules stay active, and connections with no rule are allowed as usual. Activity may have gaps until you open Rift again.", bundle: .module)
        }
    }
}
