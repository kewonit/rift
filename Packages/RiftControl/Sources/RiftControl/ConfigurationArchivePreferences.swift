import Foundation

/// Settings Rift keeps outside the configuration database that still change
/// what gets blocked or which profile is active. A configuration archive
/// carries them, so a restore on this Mac or another one brings them back.
public struct ConfigurationArchivePreferences: Sendable, Hashable, Codable {
    public static let maximumSubscriptions = 10_000
    public static let maximumNetworks = 1_000
    public static let maximumTextScalars = 512

    public var blocklistSubscriptions: [ArchivedBlocklistSubscription]
    public var networkProfiles: ArchivedNetworkProfiles
    public var alerts: ArchivedAlertPreferences

    public init(
        blocklistSubscriptions: [ArchivedBlocklistSubscription],
        networkProfiles: ArchivedNetworkProfiles,
        alerts: ArchivedAlertPreferences
    ) {
        self.blocklistSubscriptions = blocklistSubscriptions
        self.networkProfiles = networkProfiles
        self.alerts = alerts
    }

    /// Drops what the configuration beside it can't support: subscriptions
    /// for blocklists it doesn't have, and network choices naming profiles
    /// it doesn't have, which then leave the profile as it is.
    public func sanitized(profileIDs: Set<UUID>, blocklistIDs: Set<UUID>) -> Self {
        var copy = self
        var seen: Set<UUID> = []
        copy.blocklistSubscriptions = blocklistSubscriptions
            .filter { blocklistIDs.contains($0.blocklistID) && seen.insert($0.blocklistID).inserted }
            .sorted { $0.blocklistID.uuidString < $1.blocklistID.uuidString }
        copy.networkProfiles = networkProfiles.sanitized(profileIDs: profileIDs)
        copy.alerts = alerts.normalized
        return copy
    }

    /// Whether an archive's copy is exactly what Rift would have written for
    /// that configuration. Anything else means the file was edited.
    public func isValid(profileIDs: Set<UUID>, blocklistIDs: Set<UUID>) -> Bool {
        guard blocklistSubscriptions.count <= Self.maximumSubscriptions,
              networkProfiles.remembered.count <= Self.maximumNetworks,
              blocklistSubscriptions.allSatisfy({
                  (try? BlocklistSubscriptionAddress.validate($0.url.absoluteString)) == $0.url
              }),
              networkProfiles.remembered.allSatisfy({
                  $0.key.unicodeScalars.count <= Self.maximumTextScalars
                      && $0.name.unicodeScalars.count <= Self.maximumTextScalars
              }) else { return false }
        return sanitized(profileIDs: profileIDs, blocklistIDs: blocklistIDs) == self
    }
}

/// A subscription keeps its blocklist's ID and address. When and how it was
/// last checked isn't kept, so the restored list is checked again soon.
public struct ArchivedBlocklistSubscription: Sendable, Hashable, Codable {
    public let blocklistID: UUID
    public let url: URL
    /// Nil for daily, so archives made before intervals keep their shape.
    public let interval: BlocklistUpdateInterval?

    public init(blocklistID: UUID, url: URL, interval: BlocklistUpdateInterval? = nil) {
        self.blocklistID = blocklistID
        self.url = url
        self.interval = interval == .daily ? nil : interval
    }
}

/// Settings › Networks. Remembered networks include Wi-Fi names and router
/// addresses when profile switching by network is on.
public struct ArchivedNetworkProfiles: Sendable, Hashable, Codable {
    public var enabled: Bool
    public var notifies: Bool
    public var usesWiFiNames: Bool
    public var otherNetworks: NetworkProfileChoice
    public var remembered: [RememberedNetwork]

    public init(
        enabled: Bool,
        notifies: Bool,
        usesWiFiNames: Bool,
        otherNetworks: NetworkProfileChoice,
        remembered: [RememberedNetwork]
    ) {
        self.enabled = enabled
        self.notifies = notifies
        self.usesWiFiNames = usesWiFiNames
        self.otherNetworks = otherNetworks
        self.remembered = remembered
    }

    func sanitized(profileIDs: Set<UUID>) -> Self {
        func supported(_ choice: NetworkProfileChoice) -> NetworkProfileChoice {
            if case .profile(let id) = choice, !profileIDs.contains(id) { return .leaveAsIs }
            return choice
        }
        var copy = self
        copy.otherNetworks = supported(otherNetworks)
        var seen: Set<String> = []
        copy.remembered = remembered
            .filter { seen.insert($0.key).inserted }
            .map { network in
                var network = network
                network.choice = supported(network.choice)
                return network
            }
            .sorted { $0.key < $1.key }
        return copy
    }
}

/// The alert settings that change what happens to a connection.
public struct ArchivedAlertPreferences: Sendable, Hashable, Codable {
    public static let scopes = ["Current profile", "All profiles"]

    /// "Block connections I don't answer".
    public var blocksUnanswered: Bool
    /// How long an alert waits for an answer. Nil for 30 seconds, so archives
    /// made before the wait could be chosen keep their shape.
    public var answerWaitSeconds: Int?
    public var defaultLifetime: String
    public var defaultDestination: String
    public var defaultScope: String

    public init(
        blocksUnanswered: Bool,
        answerWaitSeconds: Int? = nil,
        defaultLifetime: String,
        defaultDestination: String,
        defaultScope: String
    ) {
        self.blocksUnanswered = blocksUnanswered
        self.answerWaitSeconds = answerWaitSeconds == UnansweredAlertSettings.defaultWaitSeconds
            ? nil : answerWaitSeconds
        self.defaultLifetime = defaultLifetime
        self.defaultDestination = defaultDestination
        self.defaultScope = defaultScope
    }

    var normalized: Self {
        var copy = self
        let wait = UnansweredAlertSettings(
            blocks: blocksUnanswered,
            storedWaitSeconds: answerWaitSeconds ?? UnansweredAlertSettings.defaultWaitSeconds
        ).waitSeconds
        copy.answerWaitSeconds = wait == UnansweredAlertSettings.defaultWaitSeconds ? nil : wait
        copy.defaultLifetime = AlertDefaults.normalizedLifetimePreset(defaultLifetime)
        copy.defaultDestination = AlertDefaults.normalizedDestinationPreset(defaultDestination)
        if !Self.scopes.contains(defaultScope) { copy.defaultScope = Self.scopes[0] }
        return copy
    }
}
