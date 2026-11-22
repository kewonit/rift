import Foundation

/// How often Rift checks a subscribed list while it's running.
public enum BlocklistUpdateInterval: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case hourly
    case daily
    case weekly
    /// Only when the person chooses Update Now or Update All.
    case manual

    public var id: String { rawValue }

    public var seconds: TimeInterval? {
        switch self {
        case .hourly: 60 * 60
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        case .manual: nil
        }
    }

    public var title: String {
        switch self {
        case .hourly: String(localized: "Every hour", bundle: .module)
        case .daily: String(localized: "Every day", bundle: .module)
        case .weekly: String(localized: "Every week", bundle: .module)
        case .manual: String(localized: "Only when I ask", bundle: .module)
        }
    }

    /// How it reads in "Updates … from example.com".
    public var phrase: String {
        switch self {
        case .hourly: String(localized: "Updates hourly", bundle: .module)
        case .daily: String(localized: "Updates daily", bundle: .module)
        case .weekly: String(localized: "Updates weekly", bundle: .module)
        case .manual: String(localized: "Updates when you ask", bundle: .module)
        }
    }
}

/// A blocklist Rift keeps up to date from a web address the person entered.
/// Nothing is subscribed by default, and Rift never suggests a list.
public struct BlocklistSubscription: Sendable, Hashable, Codable, Identifiable {
    /// How often Rift checks for a new version while it's running, unless
    /// the person chose otherwise.
    public static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// The blocklist this subscription keeps updated.
    public let id: UUID
    public let url: URL
    public var lastCheckedAt: Date?
    public var lastChangedAt: Date?
    /// Why the last check failed, in a sentence, or nil when it worked.
    public var lastFailure: String?
    /// Validators from the server, so an unchanged list isn't downloaded
    /// again.
    public var entityTag: String?
    public var lastModified: String?
    /// Nil for daily, the default, so lists saved before this read the same.
    public var interval: BlocklistUpdateInterval?

    public var effectiveInterval: BlocklistUpdateInterval { interval ?? .daily }

    public init(
        id: UUID,
        url: URL,
        lastCheckedAt: Date? = nil,
        lastChangedAt: Date? = nil,
        interval: BlocklistUpdateInterval? = nil
    ) {
        self.id = id
        self.url = url
        self.lastCheckedAt = lastCheckedAt
        self.lastChangedAt = lastChangedAt
        self.interval = interval
    }

    /// Whether it's time to check again. A failed check is retried after an
    /// hour at most. A list checked only on request is never due.
    public func isDue(now: Date) -> Bool {
        effectiveInterval.isDue(lastCheckedAt: lastCheckedAt, failed: lastFailure != nil, now: now)
    }
}

public enum BlocklistSubscriptionError: Error, Sendable, Equatable {
    case invalidAddress
    /// Only HTTPS, so nobody on the network can change the list on the way.
    case insecureAddress
    /// A user name or password in the address would be stored in plain text.
    case credentialsInAddress
    case tooLarge
    case server(Int)
    case notAList
}

public enum BlocklistSubscriptionAddress {
    public static let maximumLength = 2_048

    /// Checks an address typed for a subscription.
    public static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumLength,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              let url = components.url else {
            throw BlocklistSubscriptionError.invalidAddress
        }
        guard scheme == "https" else { throw BlocklistSubscriptionError.insecureAddress }
        guard components.user == nil, components.password == nil else {
            throw BlocklistSubscriptionError.credentialsInAddress
        }
        return url
    }

    /// The host, for showing where a list comes from.
    public static func host(of url: URL) -> String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }
}
