import RiftControl

/// How the connection list orders apps and destinations.
enum MonitorHierarchySort: String, CaseIterable, Identifiable, Sendable {
    case activity = "Most Recent"
    case name = "Name"
    case traffic = "Total Traffic"
    case sent = "Data Sent"
    case received = "Data Received"
    case denied = "Most Blocked"

    var id: String { rawValue }

    func comparator(_ lhs: MonitorHierarchyNode, _ rhs: MonitorHierarchyNode) -> Bool {
        switch self {
        case .activity:
            if lhs.aggregate.lastSeen != rhs.aggregate.lastSeen {
                return lhs.aggregate.lastSeen > rhs.aggregate.lastSeen
            }
        case .name:
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
        case .traffic:
            let left = Self.total(lhs.aggregate)
            let right = Self.total(rhs.aggregate)
            if left != right { return left > right }
        case .sent:
            if lhs.aggregate.bytesOutbound != rhs.aggregate.bytesOutbound {
                return (lhs.aggregate.bytesOutbound ?? 0) > (rhs.aggregate.bytesOutbound ?? 0)
            }
        case .received:
            if lhs.aggregate.bytesInbound != rhs.aggregate.bytesInbound {
                return (lhs.aggregate.bytesInbound ?? 0) > (rhs.aggregate.bytesInbound ?? 0)
            }
        case .denied:
            if lhs.aggregate.denied != rhs.aggregate.denied {
                return lhs.aggregate.denied > rhs.aggregate.denied
            }
        }
        return lhs.id < rhs.id
    }

    private static func total(_ value: MonitorAggregate) -> UInt64 {
        let (sum, overflow) = (value.bytesInbound ?? 0).addingReportingOverflow(value.bytesOutbound ?? 0)
        return overflow ? .max : sum
    }
}
