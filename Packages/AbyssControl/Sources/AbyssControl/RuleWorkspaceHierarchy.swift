import AbyssCore
import Foundation

public enum RuleWorkspaceApplicationKey: Sendable, Hashable {
    case anyProcess
    case identity(ProcessIdentity)
}

public enum RuleWorkspaceNodeID: Sendable, Hashable {
    case application(RuleWorkspaceApplicationKey)
    case rule(UUID)
}

public struct RuleWorkspaceNode: Sendable, Identifiable {
    public let id: RuleWorkspaceNodeID
    public let title: String
    public let subtitle: String?
    public let applicationIdentity: ProcessIdentity?
    public let row: RuleRowViewValue?
    public let children: [RuleWorkspaceNode]?

    public var ruleIDs: Set<UUID> {
        if let row { return [row.id] }
        return Set(children?.compactMap(\.row?.id) ?? [])
    }

    fileprivate init(
        id: RuleWorkspaceNodeID,
        title: String,
        subtitle: String? = nil,
        applicationIdentity: ProcessIdentity? = nil,
        row: RuleRowViewValue? = nil,
        children: [RuleWorkspaceNode]? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.applicationIdentity = applicationIdentity
        self.row = row
        self.children = children
    }
}

public enum RuleWorkspaceHierarchy {
    public static func nodes(rows: [RuleRowViewValue]) -> [RuleWorkspaceNode] {
        var order: [RuleWorkspaceApplicationKey] = []
        var grouped: [RuleWorkspaceApplicationKey: [RuleRowViewValue]] = [:]
        for row in rows {
            let key = applicationKey(row.rule.process)
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(row)
        }

        let labels = Dictionary(grouping: order, by: title)
        return order.compactMap { key in
            guard let rows = grouped[key], !rows.isEmpty else { return nil }
            let groupTitle = title(key)
            let needsDisambiguation = (labels[groupTitle]?.count ?? 0) > 1
            return RuleWorkspaceNode(
                id: .application(key),
                title: groupTitle,
                subtitle: needsDisambiguation ? discriminator(key) : nil,
                applicationIdentity: identity(key),
                children: rows.map(ruleNode)
            )
        }
    }

    public static func nodes(
        affecting application: ProcessIdentity,
        in nodes: [RuleWorkspaceNode]
    ) -> [RuleWorkspaceNode] {
        nodes.filter { node in
            node.applicationIdentity == nil || node.applicationIdentity == application
        }
    }

    public static func ruleIDs(
        for selectedNodes: Set<RuleWorkspaceNodeID>,
        in nodes: [RuleWorkspaceNode]
    ) -> Set<UUID> {
        var result: Set<UUID> = []
        for node in nodes {
            if selectedNodes.contains(node.id) { result.formUnion(node.ruleIDs) }
            for child in node.children ?? [] where selectedNodes.contains(child.id) {
                result.formUnion(child.ruleIDs)
            }
        }
        return result
    }

    public static func nodeIDs(
        for selectedRules: Set<UUID>,
        in nodes: [RuleWorkspaceNode]
    ) -> Set<RuleWorkspaceNodeID> {
        var result: Set<RuleWorkspaceNodeID> = []
        for node in nodes {
            let childIDs = node.ruleIDs
            for child in node.children ?? [] where !child.ruleIDs.isDisjoint(with: selectedRules) {
                result.insert(child.id)
            }
            if !childIDs.isEmpty, childIDs.isSubset(of: selectedRules) {
                result.insert(node.id)
            }
        }
        return result
    }

    private static func applicationKey(_ condition: ProcessCondition) -> RuleWorkspaceApplicationKey {
        switch condition {
        case .anyProcess:
            .anyProcess
        case .exact(let identity), .appViaHelper(let identity, _):
            .identity(identity)
        }
    }

    private static func ruleNode(_ row: RuleRowViewValue) -> RuleWorkspaceNode {
        let helper: String?
        if case .appViaHelper(_, let identity) = row.rule.process {
            helper = "Via \(RuleWorkspacePresentation.identity(identity))"
        } else {
            helper = nil
        }
        return RuleWorkspaceNode(
            id: .rule(row.id),
            title: row.conditionSummary,
            subtitle: helper,
            row: row
        )
    }

    private static func title(_ key: RuleWorkspaceApplicationKey) -> String {
        switch key {
        case .anyProcess: "Any application"
        case .identity(let identity): RuleWorkspacePresentation.identity(identity)
        }
    }

    private static func identity(_ key: RuleWorkspaceApplicationKey) -> ProcessIdentity? {
        if case .identity(let identity) = key { return identity }
        return nil
    }

    private static func discriminator(_ key: RuleWorkspaceApplicationKey) -> String? {
        guard case .identity(let identity) = key else { return nil }
        let value: String
        switch identity {
        case .applePlatform(let signed), .developerID(let signed), .appStore(let signed):
            value = signed.teamIdentifier.map { "Team \($0)" } ?? "No team identifier"
        case .otherSigner(let hash, _), .adHoc(let hash):
            value = "Code \(hash.description.prefix(16))…"
        case .unsigned(let path, let hash):
            value = "\(path) • \(hash.description.prefix(16))…"
        }
        return DisplaySanitizer.plainText(value)
    }
}
