import RiftCore
import Foundation

public enum RuleListFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All Rules"
    case active = "Active"
    case denied = "Denied"
    case recentlyModified = "Recently Modified"
    case recentlyUsed = "Recently Used"
    case temporary = "Temporary"
    case unreviewed = "Unreviewed"

    public var id: String { rawValue }
}

public struct RuleUsageValue: Sendable, Hashable {
    public let lowerBoundCount: Int
    public let lastUsedAt: Date?
    public let coverage: HistoryCoverage

    public init(lowerBoundCount: Int, lastUsedAt: Date?, coverage: HistoryCoverage) {
        self.lowerBoundCount = max(0, lowerBoundCount)
        self.lastUsedAt = lastUsedAt
        self.coverage = coverage
    }
}

public struct RuleWorkspaceQueryContext: Sendable, Hashable {
    public let activeProfileID: UUID?
    public let enabledLocalGroupIDs: Set<UUID>
    public let localGroupNames: [UUID: String]
    public let profileNames: [UUID: String]
    public let blocklistNames: [UUID: String]
    public let now: Date

    public init(
        activeProfileID: UUID?,
        enabledLocalGroupIDs: Set<UUID>,
        localGroupNames: [UUID: String] = [:],
        profileNames: [UUID: String] = [:],
        blocklistNames: [UUID: String] = [:],
        now: Date
    ) {
        self.activeProfileID = activeProfileID
        self.enabledLocalGroupIDs = enabledLocalGroupIDs
        self.localGroupNames = localGroupNames
        self.profileNames = profileNames
        self.blocklistNames = blocklistNames
        self.now = now
    }

    public init(configuration: PolicyConfigurationDraft, now: Date) {
        self.init(
            activeProfileID: configuration.activeProfileID,
            enabledLocalGroupIDs: configuration.enabledLocalGroupIDs,
            localGroupNames: Dictionary(
                configuration.localGroups.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            profileNames: Dictionary(
                configuration.profiles.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            blocklistNames: Dictionary(
                configuration.blocklists.map { ($0.id, $0.name) },
                uniquingKeysWith: { first, _ in first }
            ),
            now: now
        )
    }

    func includes(_ rule: Rule) -> Bool {
        guard rule.isEnabled,
              rule.profileID.map({ $0 == activeProfileID }) ?? true,
              rule.localGroupID.map(enabledLocalGroupIDs.contains) ?? true,
              rule.expiresAt.map({ $0 > now }) ?? true else { return false }
        return true
    }
}

public struct RuleRowViewValue: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let rule: Rule
    public let actionLabel: String
    public let applicationLabel: String
    public let conditionSummary: String
    public let enforcementState: PolicyOutboxState
    public let generation: UInt64
    public let usage: RuleUsageValue

    public init(
        rule: Rule,
        state: PolicyOutboxState,
        generation: UInt64,
        usage: RuleUsageValue
    ) {
        id = rule.id
        self.rule = rule
        actionLabel = Self.action(rule.action)
        applicationLabel = RuleWorkspacePresentation.process(rule.process)
        conditionSummary = Self.condition(rule)
        enforcementState = state
        self.generation = generation
        self.usage = usage
    }

    private static func action(_ action: RuleAction) -> String {
        switch action {
        case .filter(.allow): "Allow"
        case .filter(.deny): "Deny"
        case .filter(.ask): "Ask"
        case .notification: "Notify"
        case .privacy: "Hide"
        }
    }

    private static func condition(_ rule: Rule) -> String {
        let destination: String
        switch rule.destination {
        case .ipSet(let values): destination = values.map(\.description).joined(separator: ", ")
        case .exactHostnameSet(let values): destination = values.map(\.ascii).joined(separator: ", ")
        case .domainSet(let values): destination = values.map { "*." + $0.ascii }.joined(separator: ", ")
        case .endpointClass(let value): destination = value.rawValue
        case .anyEndpoint: destination = "Any destination"
        }
        let port = rule.port.map { $0.lowerBound == $0.upperBound
            ? String($0.lowerBound) : "\($0.lowerBound)–\($0.upperBound)" } ?? "any port"
        return DisplaySanitizer.plainText("\(destination) • \(port)")
    }
}

public struct ManualRuleDraft: Sendable, Hashable {
    public let action: RuleAction
    public let priority: RulePriority
    public let process: ProcessCondition
    public let destination: DestinationCondition
    public let transport: ProtocolCondition
    public let port: PortRange?
    public let direction: DirectionCondition
    public let owner: OwnerCondition
    public let profileID: UUID?
    public let localGroupID: UUID?
    public let expiresAt: Date?
    public let isEnabled: Bool
    public let reviewState: RuleReviewState
    public let note: String

    public init(
        action: RuleAction,
        priority: RulePriority,
        process: ProcessCondition,
        destination: DestinationCondition,
        transport: ProtocolCondition,
        port: PortRange?,
        direction: DirectionCondition,
        owner: OwnerCondition,
        profileID: UUID?,
        localGroupID: UUID?,
        expiresAt: Date?,
        isEnabled: Bool,
        reviewState: RuleReviewState,
        note: String
    ) {
        self.action = action
        self.priority = priority
        self.process = process
        self.destination = destination
        self.transport = transport
        self.port = port
        self.direction = direction
        self.owner = owner
        self.profileID = profileID
        self.localGroupID = localGroupID
        self.expiresAt = expiresAt
        self.isEnabled = isEnabled
        self.reviewState = reviewState
        self.note = note
    }
}

public struct RuleIdentityChoice: Sendable, Hashable, Identifiable {
    public var id: ProcessCondition { process }
    public let process: ProcessCondition
    public let permitsSystemOwner: Bool

    public init(process: ProcessCondition, permitsSystemOwner: Bool) {
        self.process = process
        self.permitsSystemOwner = permitsSystemOwner
    }

    public var label: String {
        RuleWorkspacePresentation.process(process)
    }
}

public enum RuleMutationError: Error, Sendable, Equatable {
    case protectedRule
    case sourceManagedRule
}

public enum RuleMutation {
    public static func enabled(_ rule: Rule, value: Bool, now: Date) throws -> Rule {
        try validateInteractiveMutation(rule)
        return try copy(rule, isEnabled: value, reviewState: rule.reviewState, now: now)
    }

    public static func managedEnabled(_ rule: Rule, value: Bool, now: Date) throws -> Rule {
        guard rule.flags.contains(.sourceManaged) else { throw RuleMutationError.sourceManagedRule }
        return try copy(rule, isEnabled: value, reviewState: rule.reviewState, now: now)
    }

    public static func reviewed(_ rule: Rule, value: Bool, now: Date) throws -> Rule {
        try validateInteractiveMutation(rule)
        return try copy(rule, isEnabled: rule.isEnabled, reviewState: value ? .reviewed : .unreviewed, now: now)
    }

    public static func edited(
        _ rule: Rule,
        action: RuleAction,
        priority: RulePriority,
        process: ProcessCondition,
        destination: DestinationCondition,
        transport: ProtocolCondition,
        port: PortRange?,
        direction: DirectionCondition,
        owner: OwnerCondition,
        profileID: UUID?,
        localGroupID: UUID?,
        expiresAt: Date?,
        isEnabled: Bool,
        reviewState: RuleReviewState,
        note: String,
        now: Date
    ) throws -> Rule {
        try validateInteractiveMutation(rule)
        return try Rule(
            id: rule.id, lineageID: rule.lineageID, revision: rule.revision + 1,
            action: action, priority: priority, process: process,
            destination: destination, transportProtocol: transport, port: port,
            direction: direction, owner: owner, profileID: profileID,
            localGroupID: localGroupID, expiresAt: expiresAt,
            isEnabled: isEnabled, flags: rule.flags, reviewState: reviewState,
            source: rule.source, notes: note, createdAt: rule.createdAt, modifiedAt: now
        )
    }

    public static func duplicate(_ rule: Rule, now: Date) throws -> Rule {
        try duplicate(
            rule,
            id: UUID(),
            profileID: rule.profileID,
            localGroupID: rule.localGroupID,
            now: now
        )
    }

    public static func duplicate(
        _ rule: Rule,
        id: UUID,
        profileID: UUID?,
        localGroupID: UUID?,
        now: Date
    ) throws -> Rule {
        try validateInteractiveMutation(rule)
        return try Rule(
            id: id, lineageID: rule.lineageID, revision: 1, action: rule.action,
            priority: rule.priority, process: rule.process, destination: rule.destination,
            transportProtocol: rule.transportProtocol, port: rule.port, direction: rule.direction,
            owner: rule.owner, profileID: profileID, localGroupID: localGroupID,
            expiresAt: rule.expiresAt, isEnabled: rule.isEnabled,
            flags: rule.flags.subtracting(.protected), reviewState: rule.reviewState,
            source: .manual, notes: rule.notes, createdAt: now, modifiedAt: now
        )
    }

    public static func assigned(
        _ rule: Rule,
        profileID: UUID?,
        localGroupID: UUID?,
        now: Date
    ) throws -> Rule {
        try validateInteractiveMutation(rule)
        return try Rule(
            id: rule.id, lineageID: rule.lineageID, revision: rule.revision + 1,
            action: rule.action, priority: rule.priority, process: rule.process,
            destination: rule.destination, transportProtocol: rule.transportProtocol,
            port: rule.port, direction: rule.direction, owner: rule.owner,
            profileID: profileID, localGroupID: localGroupID,
            expiresAt: rule.expiresAt, isEnabled: rule.isEnabled,
            flags: rule.flags, reviewState: rule.reviewState, source: rule.source,
            notes: rule.notes, createdAt: rule.createdAt, modifiedAt: now
        )
    }

    public static func removingGroup(_ rule: Rule, now: Date) throws -> Rule {
        try copyAssignment(rule, profileID: rule.profileID, localGroupID: nil, now: now)
    }

    public static func removingProfile(_ rule: Rule, now: Date) throws -> Rule {
        try copyAssignment(rule, profileID: nil, localGroupID: rule.localGroupID, now: now)
    }

    private static func copyAssignment(
        _ rule: Rule,
        profileID: UUID?,
        localGroupID: UUID?,
        now: Date
    ) throws -> Rule {
        try Rule(
            id: rule.id, lineageID: rule.lineageID, revision: rule.revision + 1,
            action: rule.action, priority: rule.priority, process: rule.process,
            destination: rule.destination, transportProtocol: rule.transportProtocol,
            port: rule.port, direction: rule.direction, owner: rule.owner,
            profileID: profileID, localGroupID: localGroupID,
            expiresAt: rule.expiresAt, isEnabled: rule.isEnabled,
            flags: rule.flags, reviewState: rule.reviewState, source: rule.source,
            notes: rule.notes, createdAt: rule.createdAt, modifiedAt: now
        )
    }

    private static func validateInteractiveMutation(_ rule: Rule) throws {
        guard !rule.flags.contains(.protected) else { throw RuleMutationError.protectedRule }
        guard !rule.flags.contains(.sourceManaged) else { throw RuleMutationError.sourceManagedRule }
    }

    private static func copy(
        _ rule: Rule,
        isEnabled: Bool,
        reviewState: RuleReviewState,
        now: Date
    ) throws -> Rule {
        try Rule(
            id: rule.id,
            lineageID: rule.lineageID,
            revision: rule.revision + 1,
            action: rule.action,
            priority: rule.priority,
            process: rule.process,
            destination: rule.destination,
            transportProtocol: rule.transportProtocol,
            port: rule.port,
            direction: rule.direction,
            owner: rule.owner,
            profileID: rule.profileID,
            localGroupID: rule.localGroupID,
            expiresAt: rule.expiresAt,
            isEnabled: isEnabled,
            flags: rule.flags,
            reviewState: reviewState,
            source: rule.source,
            notes: rule.notes,
            createdAt: rule.createdAt,
            modifiedAt: now
        )
    }
}

public enum DestinationEditorError: Error, Sendable, Equatable {
    case empty
    case mixedTypes
    case malformed
    case overLimit
    case childDomainsUnavailable
}

public enum DestinationEditorParser {
    public static func parse(_ text: String, domainsIncludeChildren: Bool) throws -> DestinationCondition {
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw DestinationEditorError.empty }
        guard tokens.count <= PolicyLimits.maximumDestinationMembers else {
            throw DestinationEditorError.overLimit
        }
        var intervals: [IPInterval] = []
        var domains: [DomainName] = []
        for token in tokens {
            if let interval = try? parseIP(token) {
                guard domains.isEmpty else { throw DestinationEditorError.mixedTypes }
                intervals.append(interval)
            } else if let domain = try? DomainName(token) {
                guard intervals.isEmpty else { throw DestinationEditorError.mixedTypes }
                domains.append(domain)
            } else {
                throw DestinationEditorError.malformed
            }
        }
        if !intervals.isEmpty { return try .normalizedIPSet(intervals) }
        guard !domainsIncludeChildren else {
            throw DestinationEditorError.childDomainsUnavailable
        }
        return try .normalizedExactHostnameSet(domains)
    }

    private static func parseIP(_ token: String) throws -> IPInterval {
        if token.contains("/") {
            let parts = token.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let prefix = Int(parts[1]) else {
                throw DestinationEditorError.malformed
            }
            return try IPInterval(cidr: IPAddress(String(parts[0])), prefixLength: prefix)
        }
        if token.contains("-") {
            let parts = token.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw DestinationEditorError.malformed }
            return try IPInterval(range: IPAddress(String(parts[0])), IPAddress(String(parts[1])))
        }
        return IPInterval(exact: try IPAddress(token))
    }
}
