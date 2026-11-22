import Foundation
import RiftControl

/// The settings outside the configuration database that a configuration
/// archive carries: blocklist and rule group subscriptions, Settings ›
/// Networks, and the alert settings that change what happens to a connection.
@MainActor
enum ArchivedAppPreferences {
    static func current() -> ConfigurationArchivePreferences {
        let defaults = UserDefaults.standard
        return ConfigurationArchivePreferences(
            blocklistSubscriptions: BlocklistSubscriptions.shared.archived,
            networkProfiles: NetworkProfileSwitcher.shared.archived,
            alerts: ArchivedAlertPreferences(
                blocksUnanswered: defaults.bool(forKey: ConnectionAlertCountdown.blocksUnansweredKey),
                answerWaitSeconds: ControlPlaneController.unansweredAlertSettings.waitSeconds,
                defaultLifetime: defaults.string(forKey: AlertDefaults.lifetimeKey) ?? AlertDefaults.lastUsed,
                defaultDestination: defaults.string(forKey: AlertDefaults.destinationKey) ?? AlertDefaults.lastUsed,
                defaultScope: defaults.string(forKey: AlertDefaults.scopeKey) ?? ArchivedAlertPreferences.scopes[0]
            ),
            ruleGroupSubscriptions: RuleGroupSubscriptions.shared.archived
        )
    }

    static func apply(_ preferences: ConfigurationArchivePreferences) {
        BlocklistSubscriptions.shared.restore(preferences.blocklistSubscriptions)
        RuleGroupSubscriptions.shared.restore(preferences.ruleGroupSubscriptions)
        NetworkProfileSwitcher.shared.restore(preferences.networkProfiles)
        let defaults = UserDefaults.standard
        defaults.set(preferences.alerts.blocksUnanswered, forKey: ConnectionAlertCountdown.blocksUnansweredKey)
        defaults.set(
            preferences.alerts.answerWaitSeconds ?? UnansweredAlertSettings.defaultWaitSeconds,
            forKey: UnansweredAlertSettings.waitSecondsKey
        )
        defaults.set(preferences.alerts.defaultLifetime, forKey: AlertDefaults.lifetimeKey)
        defaults.set(preferences.alerts.defaultDestination, forKey: AlertDefaults.destinationKey)
        defaults.set(preferences.alerts.defaultScope, forKey: AlertDefaults.scopeKey)
    }

    /// What a restore brings back besides the configuration, in a sentence.
    /// riftctl prints it too, so it's in English while `RiftLocale.english` is set.
    static func summary(_ preferences: ConfigurationArchivePreferences) -> String {
        let subscriptions = preferences.blocklistSubscriptions.count
        let groups = preferences.ruleGroupSubscriptions?.count ?? 0
        let networks = preferences.networkProfiles.remembered.count
        var parts = [String(localized: "\(subscriptions) blocklist subscriptions", bundle: RiftLocale.mainBundle)]
        if groups > 0 { parts.append(String(localized: "\(groups) rule group subscriptions", bundle: RiftLocale.mainBundle)) }
        parts.append(String(localized: "\(networks) remembered networks", bundle: RiftLocale.mainBundle))
        parts.append(preferences.alerts.blocksUnanswered
            ? String(localized: "alert settings (unanswered connections are blocked)", bundle: RiftLocale.mainBundle)
            : String(localized: "alert settings", bundle: RiftLocale.mainBundle))
        return String(
            localized: "Also restores \(RiftLocale.list(parts)).", bundle: RiftLocale.mainBundle,
            comment: "A list of what a restore brings back, like “2 blocklist subscriptions and alert settings”"
        )
    }
}
