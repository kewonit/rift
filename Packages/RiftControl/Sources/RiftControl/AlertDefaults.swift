import Foundation

/// How long an answer given in an alert lasts. The raw value is what Settings
/// stores, so values saved by earlier versions keep working.
public enum AlertLifetime: String, CaseIterable, Identifiable, Sendable {
    case once = "Once"
    case fiveMinutes = "Five minutes"
    case fifteenMinutes = "Fifteen minutes"
    case oneHour = "One hour"
    case oneDay = "One day"
    case oneWeek = "One week"
    case permanent = "Always"

    public var id: String { rawValue }

    /// Reads a stored value, including "Permanent" from earlier versions.
    public init?(stored: String) {
        if stored == "Permanent" {
            self = .permanent
        } else {
            self.init(rawValue: stored)
        }
    }

    /// How long a rule made with this lifetime lasts. `nil` for Once, which
    /// makes no rule, and for Always, which never expires.
    public var duration: TimeInterval? {
        switch self {
        case .once, .permanent: nil
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .oneHour: 3_600
        case .oneDay: 86_400
        case .oneWeek: 604_800
        }
    }

    /// The label in the alert's Remember menu.
    public var menuTitle: String {
        switch self {
        case .once: String(localized: "Only this time", bundle: .module)
        case .fiveMinutes: String(localized: "For 5 minutes", bundle: .module)
        case .fifteenMinutes: String(localized: "For 15 minutes", bundle: .module)
        case .oneHour: String(localized: "For 1 hour", bundle: .module)
        case .oneDay: String(localized: "For 1 day", bundle: .module)
        case .oneWeek: String(localized: "For 1 week", bundle: .module)
        case .permanent: String(localized: "Always", bundle: .module)
        }
    }

    /// The name in Settings. The raw value is what's stored, so it stays in English.
    public var displayName: String {
        switch self {
        case .once: String(localized: "Once", bundle: .module)
        case .fiveMinutes: String(localized: "Five minutes", bundle: .module)
        case .fifteenMinutes: String(localized: "Fifteen minutes", bundle: .module)
        case .oneHour: String(localized: "One hour", bundle: .module)
        case .oneDay: String(localized: "One day", bundle: .module)
        case .oneWeek: String(localized: "One week", bundle: .module)
        case .permanent: String(localized: "Always", bundle: .module)
        }
    }

    /// How long a rule lasts, as the end of a sentence, or nil when the
    /// answer makes no rule that expires.
    public var phrase: String? {
        switch self {
        case .once, .permanent: nil
        case .fiveMinutes: String(localized: "five minutes", bundle: .module)
        case .fifteenMinutes: String(localized: "fifteen minutes", bundle: .module)
        case .oneHour: String(localized: "one hour", bundle: .module)
        case .oneDay: String(localized: "one day", bundle: .module)
        case .oneWeek: String(localized: "one week", bundle: .module)
        }
    }
}

/// What a rule made from an alert covers.
public enum AlertDestinationChoice: String, CaseIterable, Identifiable, Sendable {
    case exact = "This destination"
    case anyPort = "This destination, any port"
    case domain = "This domain"
    case any = "Any destination"

    public var id: String { rawValue }

    /// The words for this choice. The raw value is what's stored, so it stays in English.
    public var displayName: String {
        switch self {
        case .exact: String(localized: "This destination", bundle: .module)
        case .anyPort: String(localized: "This destination, any port", bundle: .module)
        case .domain: String(localized: "This domain", bundle: .module)
        case .any: String(localized: "Any destination", bundle: .module)
        }
    }

    public var ruleScope: AlertDestinationScope {
        switch self {
        case .exact: .exactObservedEndpoint
        case .anyPort: .observedDestinationAnyPort
        case .domain: .observedDomain
        case .any: .anyEndpoint
        }
    }
}

/// What a new alert preselects. Each preset is either a fixed choice or
/// "Last used", which follows the most recent lasting answer. With nothing
/// used yet, an alert offers a rule that lasts, for the whole domain, so the
/// same app doesn't ask again for the next name under it.
public enum AlertDefaults {
    public static let lastUsed = "Last used"

    public static let lifetimeKey = "alertDefaultLifetime"
    public static let destinationKey = "alertDefaultDestination"
    public static let scopeKey = "alertDefaultScope"
    public static let lastLifetimeKey = "alertLastLifetime"
    public static let lastDestinationKey = "alertLastDestination"

    public static let factoryLifetime = AlertLifetime.permanent
    public static let factoryDestination = AlertDestinationChoice.domain

    /// The destination choices a preset can name. Any destination is left
    /// out because an alert never preselects it.
    public static let presetDestinations: [AlertDestinationChoice] = [.exact, .anyPort, .domain]

    public static func lifetime(preset: String, lastUsed: String?) -> AlertLifetime {
        if preset == Self.lastUsed {
            return lastUsed.flatMap(AlertLifetime.init(stored:)) ?? factoryLifetime
        }
        return AlertLifetime(stored: preset) ?? factoryLifetime
    }

    /// A domain choice falls back to the exact destination when the
    /// connection has no name to take a domain from, such as an IP-only or
    /// incoming connection.
    public static func destination(
        preset: String,
        lastUsed: String?,
        domainAvailable: Bool
    ) -> AlertDestinationChoice {
        let stored = preset == Self.lastUsed ? lastUsed : preset
        var wanted = stored.flatMap(AlertDestinationChoice.init(rawValue:)) ?? factoryDestination
        if wanted == .any { wanted = factoryDestination }
        if wanted == .domain, !domainAvailable { return .exact }
        return wanted
    }

    /// Whether an answer becomes the new "Last used" destination. An answer
    /// to an alert that couldn't offer a domain doesn't count, so one IP-only
    /// connection doesn't undo a domain preference.
    public static func remembersDestination(
        _ choice: AlertDestinationChoice,
        domainAvailable: Bool
    ) -> Bool {
        domainAvailable && choice != .any
    }

    /// A stored lifetime preset, or "Last used" when it isn't one Rift knows.
    public static func normalizedLifetimePreset(_ stored: String) -> String {
        if stored == Self.lastUsed { return stored }
        return AlertLifetime(stored: stored)?.rawValue ?? Self.lastUsed
    }

    /// A stored destination preset, or "Last used" when it isn't one Rift knows.
    public static func normalizedDestinationPreset(_ stored: String) -> String {
        if stored == Self.lastUsed { return stored }
        guard let choice = AlertDestinationChoice(rawValue: stored),
              presetDestinations.contains(choice) else { return Self.lastUsed }
        return stored
    }
}
