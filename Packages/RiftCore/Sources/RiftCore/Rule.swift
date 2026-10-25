import Foundation

public enum FilterAction: String, Sendable, Hashable, Codable {
    case allow
    case deny
    case ask
}

public enum NotificationAction: String, Sendable, Hashable, Codable {
    case notify
}

public enum PrivacyAction: String, Sendable, Hashable, Codable {
    case hide
}

public enum RuleAction: Sendable, Hashable, Codable {
    case filter(FilterAction)
    case notification(NotificationAction)
    case privacy(PrivacyAction)
}

public enum RulePriority: String, Sendable, Hashable, Codable {
    case elevatedUser
    case blocklistDeny
    case normal
}

public enum RuleReviewState: String, Sendable, Hashable, Codable {
    case reviewed
    case unreviewed
}

public enum RuleSource: Sendable, Hashable, Codable {
    case manual
    case imported
    case blocklist(sourceID: UUID)
    case feature(identifier: String)
}

public struct RuleFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let protected = RuleFlags(rawValue: 1 << 0)
    public static let sourceManaged = RuleFlags(rawValue: 1 << 1)
}

public enum RuleValidationError: Error, Sendable, Equatable {
    case notesTooLong
    case blocklistMustDeny
    case blocklistPriorityRequiresManagedSource
    case blocklistRequiresManagedFlag
    case elevatedPriorityRequiresAllow
    case elevatedPriorityRequiresExactProcess
    case elevatedPriorityRequiresExactDestination
    case unsupportedEndpointClass(EndpointClass)
}

public struct Rule: Sendable, Hashable, Codable {
    public static let schemaVersion: UInt16 = 1

    public let id: UUID
    public let lineageID: UUID
    public let revision: UInt64
    public let action: RuleAction
    public let priority: RulePriority
    public let process: ProcessCondition
    public let destination: DestinationCondition
    public let transportProtocol: ProtocolCondition
    public let port: PortRange?
    public let direction: DirectionCondition
    public let owner: OwnerCondition
    public let profileID: UUID?
    public let localGroupID: UUID?
    public let expiresAt: Date?
    public let isEnabled: Bool
    public let flags: RuleFlags
    public let reviewState: RuleReviewState
    public let source: RuleSource
    public let notes: String
    public let createdAt: Date
    public let modifiedAt: Date

    public init(
        id: UUID,
        lineageID: UUID,
        revision: UInt64,
        action: RuleAction,
        priority: RulePriority,
        process: ProcessCondition,
        destination: DestinationCondition,
        transportProtocol: ProtocolCondition,
        port: PortRange?,
        direction: DirectionCondition,
        owner: OwnerCondition,
        profileID: UUID? = nil,
        localGroupID: UUID? = nil,
        expiresAt: Date? = nil,
        isEnabled: Bool = true,
        flags: RuleFlags = [],
        reviewState: RuleReviewState = .reviewed,
        source: RuleSource = .manual,
        notes: String = "",
        createdAt: Date,
        modifiedAt: Date
    ) throws {
        guard notes.unicodeScalars.count <= PolicyLimits.maximumNotesScalars else {
            throw RuleValidationError.notesTooLong
        }
        let normalizedDestination = try destination.validated()
        if case .endpointClass(let value) = normalizedDestination,
           ![.broadcast, .multicast, .bonjour, .localNetwork].contains(value) {
            throw RuleValidationError.unsupportedEndpointClass(value)
        }
        if case .blocklist(sourceID: _) = source {
            guard action == .filter(.deny) else { throw RuleValidationError.blocklistMustDeny }
            guard flags.contains(.sourceManaged) else {
                throw RuleValidationError.blocklistRequiresManagedFlag
            }
        }
        if priority == .blocklistDeny {
            guard case .blocklist(sourceID: _) = source else {
                throw RuleValidationError.blocklistPriorityRequiresManagedSource
            }
            guard action == .filter(.deny) else { throw RuleValidationError.blocklistMustDeny }
        }
        try Self.validatePriorityScope(
            action: action,
            priority: priority,
            process: process,
            destination: normalizedDestination
        )

        self.id = id
        self.lineageID = lineageID
        self.revision = revision
        self.action = action
        self.priority = priority
        self.process = process
        self.destination = normalizedDestination
        self.transportProtocol = transportProtocol
        self.port = port
        self.direction = direction
        self.owner = owner
        self.profileID = profileID
        self.localGroupID = localGroupID
        self.expiresAt = expiresAt
        self.isEnabled = isEnabled
        self.flags = flags
        self.reviewState = reviewState
        self.source = source
        self.notes = notes
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var expiryKey: ExpiredRuleKey? {
        expiresAt.map {
            ExpiredRuleKey(lineageID: lineageID, ruleID: id, revision: revision, expiresAt: $0)
        }
    }

    public static func validatePriorityScope(
        action: RuleAction,
        priority: RulePriority,
        process: ProcessCondition,
        destination: DestinationCondition
    ) throws {
        guard priority == .elevatedUser else { return }
        guard action == .filter(.allow) else {
            throw RuleValidationError.elevatedPriorityRequiresAllow
        }
        switch process {
        case .anyProcess:
            throw RuleValidationError.elevatedPriorityRequiresExactProcess
        case .exact(let identity):
            _ = try identity.validated()
        case .appViaHelper(let app, let helper):
            _ = try app.validated()
            _ = try helper.validated()
        }
        switch destination {
        case .ipSet, .exactHostnameSet:
            _ = try destination.validated()
        case .domainSet, .endpointClass, .anyEndpoint:
            throw RuleValidationError.elevatedPriorityRequiresExactDestination
        }
    }

    public func validateStoredRepresentation() throws {
        guard notes.unicodeScalars.count <= PolicyLimits.maximumNotesScalars else {
            throw RuleValidationError.notesTooLong
        }
        if let port {
            _ = try PortRange(port.lowerBound, port.upperBound)
        }
        if case .ipSet(let intervals) = destination {
            for interval in intervals {
                _ = try IPInterval(range: interval.lowerBound, interval.upperBound)
            }
        }
        guard try destination.validated() == destination else {
            throw DestinationConditionError.nonCanonical
        }
        if case .endpointClass(let value) = destination,
           ![.broadcast, .multicast, .bonjour, .localNetwork].contains(value) {
            throw RuleValidationError.unsupportedEndpointClass(value)
        }
        switch process {
        case .anyProcess:
            break
        case .exact(let identity):
            _ = try identity.validated()
        case .appViaHelper(let app, let helper):
            _ = try app.validated()
            _ = try helper.validated()
        }
        if case .blocklist(sourceID: _) = source, action != .filter(.deny) {
            throw RuleValidationError.blocklistMustDeny
        }
        if case .blocklist(sourceID: _) = source, !flags.contains(.sourceManaged) {
            throw RuleValidationError.blocklistRequiresManagedFlag
        }
        if priority == .blocklistDeny {
            guard case .blocklist(sourceID: _) = source else {
                throw RuleValidationError.blocklistPriorityRequiresManagedSource
            }
            guard action == .filter(.deny) else { throw RuleValidationError.blocklistMustDeny }
        }
        try Self.validatePriorityScope(
            action: action,
            priority: priority,
            process: process,
            destination: destination
        )
    }
}
