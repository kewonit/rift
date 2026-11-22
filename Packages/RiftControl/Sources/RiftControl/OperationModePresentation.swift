import Foundation
import RiftCore

/// The words for each mode. The names describe what happens to a connection
/// with no rule, so someone can predict a mode without learning its meaning.
/// `riftctl status` prints the name, so the words come from `RiftLocale.bundle`.
extension OperationMode {
    public static let choices: [OperationMode] = [.silentAllow, .alert, .silentDeny, .filterOff]

    public var displayName: String {
        switch self {
        case .alert: String(localized: "Ask Me", bundle: RiftLocale.bundle)
        case .silentAllow: String(localized: "Allow and Watch", bundle: RiftLocale.bundle)
        case .silentDeny: String(localized: "Block Unless Allowed", bundle: RiftLocale.bundle)
        case .filterOff: String(localized: "Pause Rules", bundle: RiftLocale.bundle)
        case .degradedFallback: String(localized: "Unknown", bundle: RiftLocale.bundle)
        }
    }

    public var summary: String {
        switch self {
        case .alert: String(localized: "Ask about new connections with no rule.", bundle: RiftLocale.bundle)
        case .silentAllow: String(localized: "Allow new connections unless a rule blocks them.", bundle: RiftLocale.bundle)
        case .silentDeny: String(localized: "Block new connections unless a rule allows them.", bundle: RiftLocale.bundle)
        case .filterOff: String(localized: "Allow everything and turn your rules off.", bundle: RiftLocale.bundle)
        case .degradedFallback: String(localized: "Rift can’t confirm how connections are handled.", bundle: RiftLocale.bundle)
        }
    }

    public var needsConfirmation: Bool { self == .silentDeny || self == .filterOff }

    public var confirmationTitle: String {
        self == .filterOff ? String(localized: "Pause your rules?", bundle: RiftLocale.bundle) : String(localized: "Block everything without an allow rule?", bundle: RiftLocale.bundle)
    }

    public var confirmationMessage: String {
        self == .filterOff
            ? String(localized: "Rift will allow all connections and stop applying your rules. You’ll still see activity.", bundle: RiftLocale.bundle)
            : String(localized: "Rift will block every connection that no rule allows. Apps without an allow rule lose network access. Rift filters TCP and UDP only, so other traffic, such as ping, isn’t blocked.", bundle: RiftLocale.bundle)
    }

    /// What happens to connections while Rift isn't running. The filter keeps
    /// working, but it can't ask anyone.
    public var quitMessage: String {
        switch self {
        case .alert:
            String(localized: "Your rules stay active, but Rift can’t ask while it’s closed, so connections with no rule are allowed until you open it again.", bundle: RiftLocale.bundle)
        case .silentDeny:
            String(localized: "Your rules stay active, and connections with no rule stay blocked. Activity may have gaps until you open Rift again.", bundle: RiftLocale.bundle)
        case .filterOff:
            String(localized: "All connections stay allowed and your rules stay off until you change the mode.", bundle: RiftLocale.bundle)
        case .silentAllow, .degradedFallback:
            String(localized: "Your rules stay active, and connections with no rule are allowed as usual. Activity may have gaps until you open Rift again.", bundle: RiftLocale.bundle)
        }
    }
}
