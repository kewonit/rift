/// Holds a list still while someone is pointing at it, so a row can't move
/// under the pointer just before a click.
public enum MonitorHierarchyOrder {
    public static func keepingPositions(
        of previous: [MonitorHierarchyNode],
        in updated: [MonitorHierarchyNode]
    ) -> [MonitorHierarchyNode] {
        let positions = Dictionary(
            previous.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let children = Dictionary(
            previous.map { ($0.id, $0.children) },
            uniquingKeysWith: { first, _ in first }
        )
        let kept = updated.enumerated().sorted { lhs, rhs in
            switch (positions[lhs.element.id], positions[rhs.element.id]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }
        return kept.map { entry in
            let node = entry.element
            guard let newChildren = node.children, let oldChildren = children[node.id] ?? nil else {
                return node
            }
            return MonitorHierarchyNode(
                id: node.id, kind: node.kind, title: node.title, subtitle: node.subtitle,
                aggregate: node.aggregate, ruleCoverage: node.ruleCoverage,
                eventIDs: node.eventIDs, eventID: node.eventID,
                exactRuleSeed: node.exactRuleSeed, ruleSeedEventID: node.ruleSeedEventID,
                presentationIdentity: node.presentationIdentity,
                children: keepingPositions(of: oldChildren, in: newChildren)
            )
        }
    }
}
