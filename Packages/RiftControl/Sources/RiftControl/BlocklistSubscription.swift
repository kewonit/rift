import Foundation

/// A blocklist Rift keeps up to date from a web address the person entered.
/// Nothing is subscribed by default, and Rift never suggests a list.
public struct BlocklistSubscription: Sendable, Hashable, Codable, Identifiable {
    /// How often Rift checks for a new version while it's running.
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

    public init(id: UUID, url: URL, lastCheckedAt: Date? = nil, lastChangedAt: Date? = nil) {
        self.id = id
        self.url = url
        self.lastCheckedAt = lastCheckedAt
        self.lastChangedAt = lastChangedAt
    }

    /// Whether it's time to check again. A failed check is retried after an
    /// hour rather than a day.
    public func isDue(now: Date) -> Bool {
        guard let lastCheckedAt else { return true }
        let wait = lastFailure == nil ? Self.refreshInterval : 60 * 60
        return now.timeIntervalSince(lastCheckedAt) >= wait
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
