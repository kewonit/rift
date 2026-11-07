/// Decides what stays selected after the list is rebuilt. The row someone
/// picked always wins. A connection only stands in for it once that row is gone.
public enum MonitorSelectionResolver {
    public static func resolve(
        selectionID: String?,
        eventID: String?,
        in hierarchy: [MonitorHierarchyNode]
    ) -> String? {
        if let selectionID, MonitorHierarchyBuilder.node(withID: selectionID, in: hierarchy) != nil {
            return selectionID
        }
        guard let eventID else { return nil }
        return MonitorHierarchyBuilder.node(forEventID: eventID, in: hierarchy)?.id
    }

    /// The groups that must be open for a connection's row to be visible.
    public static func ancestors(
        ofEventID eventID: String,
        in nodes: [MonitorHierarchyNode]
    ) -> [String] {
        for node in nodes {
            if node.eventID == eventID { return [] }
            guard node.eventIDs.contains(eventID), let children = node.children else { continue }
            return [node.id] + ancestors(ofEventID: eventID, in: children)
        }
        return []
    }
}
