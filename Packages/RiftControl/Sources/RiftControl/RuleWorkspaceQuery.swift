import RiftCore
import Foundation

public enum RuleSearchScope: String, CaseIterable, Sendable, Identifiable {
    case all = "All Fields"
    case application = "Application"
    case match = "Match"
    case scope = "Scope"
    case notes = "Notes"

    public var id: String { rawValue }
}

public enum RuleActionFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All Actions"
    case allow = "Allow"
    case deny = "Deny"
    case ask = "Ask"
    case notify = "Notify"
    case hide = "Hide"

    public var id: String { rawValue }

    fileprivate func includes(_ action: RuleAction) -> Bool {
        switch (self, action) {
        case (.all, _), (.allow, .filter(.allow)), (.deny, .filter(.deny)),
             (.ask, .filter(.ask)), (.notify, .notification), (.hide, .privacy):
            true
        default:
            false
        }
    }
}

public enum RuleWorkspaceSort: String, CaseIterable, Sendable, Identifiable {
    case automatic = "Automatic"
    case application = "Application"
    case condition = "Condition"
    case action = "Action"
    case modified = "Modified"
    case usage = "Usage"

    public var id: String { rawValue }
}

public enum RuleCollectionFilter: Sendable, Hashable {
    case all
    case profile(UUID)
    case localGroup(UUID)
    case blocklist(UUID)

    fileprivate func includes(_ rule: Rule) -> Bool {
        switch self {
        case .all:
            true
        case .profile(let id):
            rule.profileID == id
        case .localGroup(let id):
            rule.localGroupID == id
        case .blocklist(let id):
            rule.source == .blocklist(sourceID: id)
        }
    }
}

public enum RuleWorkspacePresentation {
    public static func process(_ condition: ProcessCondition) -> String {
        switch condition {
        case .anyProcess:
            "Any application"
        case .exact(let identity):
            self.identity(identity)
        case .appViaHelper(let app, let helper):
            "\(identity(app)) via \(identity(helper))"
        }
    }

    public static func identity(_ identity: ProcessIdentity) -> String {
        let value: String
        switch identity {
        case .applePlatform(let signed):
            value = "Apple • \(signed.signingIdentifier)"
        case .developerID(let signed):
            value = "Developer ID • \(signed.signingIdentifier)"
        case .appStore(let signed):
            value = "App Store • \(signed.signingIdentifier)"
        case .otherSigner(_, let identifier):
            value = "Signed • \(identifier)"
        case .adHoc(let hash):
            value = "Ad hoc • \(hash.description.prefix(12))…"
        case .unsigned(let path, _):
            value = "Unsigned • \(path)"
        }
        return DisplaySanitizer.plainText(value)
    }
}

public enum RuleWorkspaceQuery {
    public static func rows(
        rules: [Rule],
        state: PolicyOutboxState,
        generation: UInt64,
        filter: RuleListFilter,
        search: String,
        searchScope: RuleSearchScope = .all,
        actionFilter: RuleActionFilter = .all,
        collection: RuleCollectionFilter = .all,
        sort: RuleWorkspaceSort = .automatic,
        context: RuleWorkspaceQueryContext? = nil,
        usage: [UUID: RuleUsageValue] = [:]
    ) -> [RuleRowViewValue] {
        let tokens = searchTokens(search)
        return rules.lazy
            .map { rule in
                RuleRowViewValue(
                    rule: rule,
                    state: state,
                    generation: generation,
                    usage: usage[rule.id] ?? RuleUsageValue(
                        lowerBoundCount: 0, lastUsedAt: nil, coverage: .gap
                    )
                )
            }
            .filter { row in includes(row, filter: filter, context: context) }
            .filter { collection.includes($0.rule) }
            .filter { actionFilter.includes($0.rule.action) }
            .filter { row in
                tokens.isEmpty || matches(
                    row,
                    tokens: tokens,
                    scope: searchScope,
                    context: context
                )
            }
            .sorted { ordered($0, before: $1, filter: filter, sort: sort) }
    }

    private static func includes(
        _ row: RuleRowViewValue,
        filter: RuleListFilter,
        context: RuleWorkspaceQueryContext?
    ) -> Bool {
        switch filter {
        case .all: true
        case .active: context?.includes(row.rule) == true
        case .denied: row.rule.action == .filter(.deny)
        case .recentlyModified: true
        case .recentlyUsed: row.usage.lastUsedAt != nil
        case .temporary: row.rule.expiresAt != nil
        case .unreviewed: row.rule.reviewState == .unreviewed
        }
    }

    private static func matches(
        _ row: RuleRowViewValue,
        tokens: [String],
        scope: RuleSearchScope,
        context: RuleWorkspaceQueryContext?
    ) -> Bool {
        let application = normalized(row.applicationLabel)
        let match = normalized(matchText(row.rule, summary: row.conditionSummary))
        let scopeText = normalized(ruleScopeText(row.rule, context: context))
        let notes = normalized(row.rule.notes)
        let searchable: String
        switch scope {
        case .all:
            searchable = [normalized(row.actionLabel), application, match, scopeText, notes]
                .joined(separator: " ")
        case .application: searchable = application
        case .match: searchable = match
        case .scope: searchable = scopeText
        case .notes: searchable = notes
        }
        return tokens.allSatisfy(searchable.contains)
    }

    private static func matchText(_ rule: Rule, summary: String) -> String {
        let transport: String
        switch rule.transportProtocol {
        case .tcp: transport = "TCP"
        case .udp: transport = "UDP"
        case .anySupportedProtocol: transport = "TCP UDP any protocol"
        }
        let direction: String
        switch rule.direction {
        case .outgoing: direction = "Outgoing"
        case .incoming: direction = "Incoming"
        case .bidirectional: direction = "Both directions"
        }
        return "\(summary) \(transport) \(direction)"
    }

    private static func ruleScopeText(
        _ rule: Rule,
        context: RuleWorkspaceQueryContext?
    ) -> String {
        let owner = rule.owner == .system ? "System" : "Authorized user"
        let profile = rule.profileID.flatMap { context?.profileNames[$0] } ?? "All profiles"
        let group = rule.localGroupID.flatMap { context?.localGroupNames[$0] } ?? "No group"
        let source: String
        switch rule.source {
        case .manual: source = "Manual"
        case .imported: source = "Imported"
        case .blocklist(let sourceID):
            source = context?.blocklistNames[sourceID].map { "Blocklist \($0)" } ?? "Blocklist"
        case .feature(let identifier): source = "Feature \(identifier)"
        }
        let enabled = rule.isEnabled ? "Enabled" : "Disabled"
        let reviewed = rule.reviewState == .reviewed ? "Reviewed" : "Unreviewed"
        return "\(owner) \(profile) \(group) \(source) \(enabled) \(reviewed)"
    }

    private static func ordered(
        _ lhs: RuleRowViewValue,
        before rhs: RuleRowViewValue,
        filter: RuleListFilter,
        sort: RuleWorkspaceSort
    ) -> Bool {
        let effectiveSort: RuleWorkspaceSort
        if sort == .automatic, filter == .recentlyModified {
            effectiveSort = .modified
        } else if sort == .automatic, filter == .recentlyUsed {
            effectiveSort = .usage
        } else if sort == .automatic {
            effectiveSort = .application
        } else {
            effectiveSort = sort
        }
        let order: ComparisonResult
        switch effectiveSort {
        case .automatic, .application:
            order = compare(lhs.applicationLabel, rhs.applicationLabel)
        case .condition:
            order = compare(lhs.conditionSummary, rhs.conditionSummary)
        case .action:
            order = compare(lhs.actionLabel, rhs.actionLabel)
        case .modified:
            order = lhs.rule.modifiedAt == rhs.rule.modifiedAt
                ? .orderedSame
                : (lhs.rule.modifiedAt > rhs.rule.modifiedAt ? .orderedAscending : .orderedDescending)
        case .usage:
            order = lhs.usage.lowerBoundCount == rhs.usage.lowerBoundCount
                ? .orderedSame
                : (lhs.usage.lowerBoundCount > rhs.usage.lowerBoundCount
                    ? .orderedAscending : .orderedDescending)
        }
        if order != .orderedSame { return order == .orderedAscending }
        let conditionOrder = compare(lhs.conditionSummary, rhs.conditionSummary)
        if conditionOrder != .orderedSame { return conditionOrder == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        normalized(lhs).localizedStandardCompare(normalized(rhs))
    }

    private static func searchTokens(_ value: String) -> [String] {
        normalized(value).split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func normalized(_ value: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars.prefix(2_048)
        where !scalar.properties.isBidiControl && scalar.value >= 0x20 && scalar.value != 0x7F {
            scalars.append(scalar)
        }
        return String(scalars).precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
