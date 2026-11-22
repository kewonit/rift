import RiftControl
import RiftCore
import SwiftUI

/// Clicking a column header sorts by it. Each column has one order, the one
/// the Sort By menu uses, such as most recent or most blocked first.
extension MonitorHierarchyNode {
    var sortSent: UInt64 { aggregate.bytesOutbound ?? 0 }
    var sortReceived: UInt64 { aggregate.bytesInbound ?? 0 }
}

enum ConnectionsTableSorting {
    typealias Comparator = KeyPathComparator<MonitorHierarchyNode>

    /// The header indicator for a sort. Total Traffic has no column.
    static func comparators(for sort: MonitorHierarchySort) -> [Comparator] {
        switch sort {
        case .name: [KeyPathComparator(\.title, order: .forward)]
        case .activity: [KeyPathComparator(\.aggregate.lastSeen, order: .reverse)]
        case .sent: [KeyPathComparator(\.sortSent, order: .reverse)]
        case .received: [KeyPathComparator(\.sortReceived, order: .reverse)]
        case .denied: [KeyPathComparator(\.aggregate.denied, order: .reverse)]
        case .count: [KeyPathComparator(\.aggregate.flowCount, order: .reverse)]
        case .traffic: []
        }
    }

    /// The sort a clicked header asks for.
    static func sort(for comparators: [Comparator]) -> MonitorHierarchySort? {
        guard let keyPath = comparators.first?.keyPath else { return nil }
        let columns: [(PartialKeyPath<MonitorHierarchyNode>, MonitorHierarchySort)] = [
            (\.title, .name), (\.aggregate.lastSeen, .activity), (\.sortSent, .sent),
            (\.sortReceived, .received), (\.aggregate.denied, .denied), (\.aggregate.flowCount, .count),
        ]
        return columns.first { $0.0 == keyPath }?.1
    }
}

/// Allow and Block for one row, showing what today's rules do for it.
struct QuickRuleCell: View {
    let node: MonitorHierarchyNode
    let feed: MonitorFeed

    var body: some View {
        if let breadth = feed.quickBreadth(for: node) {
            let current = node.ruleCoverage.currentAction
            let scope = scopePhrase(breadth)
            HStack(spacing: 2) {
                Button { feed.applyQuickRule(.allow, for: node) } label: {
                    Image(systemName: current == .allow ? "checkmark.circle.fill" : "checkmark.circle")
                        .foregroundStyle(current == .allow ? Color(nsColor: .systemGreen) : .secondary)
                }
                .help("Always allow \(scope)")
                .accessibilityLabel("Always allow \(scope)")
                .accessibilityAddTraits(current == .allow ? .isSelected : [])
                Button { feed.applyQuickRule(.deny, for: node) } label: {
                    Image(systemName: current == .deny ? "xmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(current == .deny ? Color(nsColor: .systemRed) : .secondary)
                }
                .help("Always block \(scope)")
                .accessibilityLabel("Always block \(scope)")
                .accessibilityAddTraits(current == .deny ? .isSelected : [])
            }
            .buttonStyle(.borderless)
            .disabled(feed.applyingEventID != nil || monitorCoveragePending(node.ruleCoverage.state))
        }
    }

    private func scopePhrase(_ breadth: MonitorRuleBreadth) -> String {
        guard let row = feed.representativeRow(for: node) else { return "this" }
        if breadth == .allDestinations { return "this app everywhere" }
        return MonitorRuleScope.phrase(
            breadth, host: DisplaySanitizer.plainText(MonitorQuery.hostnameLabel(row)),
            domain: MonitorRuleScope.domain(for: row)?.ascii
        )
    }
}

/// The Map search that shows only a row's app or destination.
enum ConnectionFocus {
    static func title(for node: MonitorHierarchyNode) -> String {
        node.kind == .application || node.kind == .helper ? "Show Only This App" : "Show Only This Destination"
    }

    static func search(for node: MonitorHierarchyNode) -> String? {
        let value = node.title.replacingOccurrences(of: "\"", with: "")
        guard !value.isEmpty else { return nil }
        return switch node.kind {
        case .application, .helper: "app:\"\(value)\""
        case .hostname, .route: "host:\(value)"
        case .domain: "domain:\(value)"
        case .address: "ip:\(value)"
        case .country, .flow: nil
        }
    }
}
