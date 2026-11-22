import Foundation
import RiftControl

/// The settings outside the configuration database that a configuration
/// archive carries: blocklist subscriptions, Settings › Networks, and the
/// alert settings that change what happens to a connection.
@MainActor
enum ArchivedAppPreferences {
    static func current() -> ConfigurationArchivePreferences {
        let defaults = UserDefaults.standard
        return ConfigurationArchivePreferences(
            blocklistSubscriptions: BlocklistSubscriptions.shared.archived,
            networkProfiles: NetworkProfileSwitcher.shared.archived,
            alerts: ArchivedAlertPreferences(
                blocksUnanswered: defaults.bool(forKey: ConnectionAlertCountdown.blocksUnansweredKey),
                defaultLifetime: defaults.string(forKey: AlertDefaults.lifetimeKey) ?? AlertDefaults.lastUsed,
                defaultDestination: defaults.string(forKey: AlertDefaults.destinationKey) ?? AlertDefaults.lastUsed,
                defaultScope: defaults.string(forKey: AlertDefaults.scopeKey) ?? ArchivedAlertPreferences.scopes[0]
            )
        )
    }

    static func apply(_ preferences: ConfigurationArchivePreferences) {
        BlocklistSubscriptions.shared.restore(preferences.blocklistSubscriptions)
        NetworkProfileSwitcher.shared.restore(preferences.networkProfiles)
        let defaults = UserDefaults.standard
        defaults.set(preferences.alerts.blocksUnanswered, forKey: ConnectionAlertCountdown.blocksUnansweredKey)
        defaults.set(preferences.alerts.defaultLifetime, forKey: AlertDefaults.lifetimeKey)
        defaults.set(preferences.alerts.defaultDestination, forKey: AlertDefaults.destinationKey)
        defaults.set(preferences.alerts.defaultScope, forKey: AlertDefaults.scopeKey)
    }

    /// What a restore brings back besides the configuration, in a sentence.
    static func summary(_ preferences: ConfigurationArchivePreferences) -> String {
        let subscriptions = preferences.blocklistSubscriptions.count
        let networks = preferences.networkProfiles.remembered.count
        let parts = [
            subscriptions == 1 ? "1 blocklist subscription" : "\(subscriptions) blocklist subscriptions",
            networks == 1 ? "1 remembered network" : "\(networks) remembered networks",
            preferences.alerts.blocksUnanswered
                ? "alert settings (unanswered connections are blocked)" : "alert settings",
        ]
        return "Also restores \(parts[0]), \(parts[1]), and \(parts[2])."
    }
}
