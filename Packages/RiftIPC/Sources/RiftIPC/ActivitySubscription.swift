import Foundation

public enum ActivityCaptureMode: String, Sendable, Hashable, Codable {
    case off
    case recent
    case persistent
}

public struct ActivitySubscription: Sendable, Hashable, Codable {
    public static let maximumRecentConnections = 50
    public static let recentLifetime: TimeInterval = 300

    public let id: UUID
    public let mode: ActivityCaptureMode
    public let maximumRecentConnections: Int
    public let notifyImplicitDecisions: Bool

    public init(id: UUID = UUID(), mode: ActivityCaptureMode, maximumRecentConnections: Int = 0,
                notifyImplicitDecisions: Bool = false) {
        self.id = id
        self.mode = mode
        self.maximumRecentConnections = maximumRecentConnections
        self.notifyImplicitDecisions = notifyImplicitDecisions
    }

    public var isValid: Bool {
        mode == .recent
            ? (1...Self.maximumRecentConnections).contains(maximumRecentConnections)
            : maximumRecentConnections == 0
    }
}

public struct RecentActivitySnapshot: Sendable, Hashable, Codable {
    public let subscriptionID: UUID
    public let providerEpoch: UUID?
    public let revision: UInt64
    public let events: [RuntimeEvent]
    public let isTruncated: Bool
    public let nextExpiry: Date?

    public init(subscriptionID: UUID, providerEpoch: UUID?, revision: UInt64,
                events: [RuntimeEvent], isTruncated: Bool, nextExpiry: Date?) {
        self.subscriptionID = subscriptionID
        self.providerEpoch = providerEpoch
        self.revision = revision
        self.events = events
        self.isTruncated = isTruncated
        self.nextExpiry = nextExpiry
    }
}

public struct RuntimeAttentionRequest: Sendable, Hashable, Codable {
    public let resyncPrompts: Bool
    public init(resyncPrompts: Bool = false) { self.resyncPrompts = resyncPrompts }
}

public struct RuntimeAttentionBatch: Sendable, Hashable, Codable {
    public let providerEpoch: UUID?
    public let prompts: [PromptRequest]
    public let activePromptNonces: Set<UUID>
    public let notifications: [EphemeralNotificationEvent]
    public let recentDenyAt: Date?

    public init(providerEpoch: UUID?, prompts: [PromptRequest], activePromptNonces: Set<UUID>,
                notifications: [EphemeralNotificationEvent], recentDenyAt: Date?) {
        self.providerEpoch = providerEpoch
        self.prompts = prompts
        self.activePromptNonces = activePromptNonces
        self.notifications = notifications
        self.recentDenyAt = recentDenyAt
    }
}
