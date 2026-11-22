import RiftControl
import RiftCore
import SwiftUI

/// The connections in the list, one line each, newest first, under day
/// headings. It follows the same search and filters as the grouped table.
struct ConnectionLogView: View {
    @Bindable var feed: MonitorFeed
    let artworkStore: ApplicationArtworkStore

    var body: some View {
        let days = Self.days(feed.displayed)
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(days, id: \.start) { day in
                    Section(Self.title(for: day.start, now: feed.now)) {
                        ForEach(day.rows) { row in
                            ConnectionLogRow(row: row.source, artworkStore: artworkStore)
                                .tag(row.id)
                                .id(row.id)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, ids.count == 1,
                   let node = MonitorHierarchyBuilder.node(forEventID: id, in: feed.hierarchy) {
                    ConnectionContextMenu(
                        canDecide: { feed.canDecide(node) },
                        disabled: feed.applyingEventID != nil || monitorCoveragePending(node.ruleCoverage.state),
                        hasRules: !node.ruleCoverage.ruleIDs.isEmpty,
                        apply: { feed.requestRule($0, for: node) },
                        showRules: { feed.showRules(for: node) },
                        copyText: feed.rowLookup[id]?.copyDescription,
                        hostname: feed.rowLookup[id]?.event.flow.observedHostname?.ascii,
                        hide: { feed.hideConnections(like: node) }
                    )
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let newest = days.first?.rows.first?.id {
                    Button {
                        withAnimation { proxy.scrollTo(newest, anchor: .top) }
                    } label: {
                        Label("Jump to Newest", systemImage: "arrow.up.to.line")
                    }
                    .controlSize(.small)
                    .padding(RiftDesign.Spacing.s)
                    .help("Scroll to the newest connection")
                }
            }
            .overlay {
                if feed.displayed.isEmpty, !feed.loading {
                    ConnectionsEmptyState(feed: feed)
                }
            }
        }
    }

    /// The selected connection, by event, mapped to its row in the grouped
    /// table so the inspector and menu commands keep working.
    private var selection: Binding<String?> {
        Binding(
            get: { feed.selectedNode?.eventID },
            set: { id in
                feed.selectionID = id.flatMap {
                    MonitorHierarchyBuilder.node(forEventID: $0, in: feed.hierarchy)?.id
                }
            }
        )
    }

    struct Day {
        let start: Date
        let rows: [MonitorDisplayRow]
    }

    static func days(_ rows: [MonitorDisplayRow], calendar: Calendar = .autoupdatingCurrent) -> [Day] {
        let sorted = rows.sorted {
            ($0.source.event.occurredAt, $0.id) > ($1.source.event.occurredAt, $1.id)
        }
        var days: [Day] = []
        var current: (start: Date, rows: [MonitorDisplayRow])?
        for row in sorted {
            let start = calendar.startOfDay(for: row.source.event.occurredAt)
            if current?.start != start {
                if let current { days.append(Day(start: current.start, rows: current.rows)) }
                current = (start, [])
            }
            current?.rows.append(row)
        }
        if let current { days.append(Day(start: current.start, rows: current.rows)) }
        return days
    }

    static func title(for day: Date, now: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day().year())
    }
}

/// One connection: when, the decision, the app, and where it went.
private struct ConnectionLogRow: View {
    let row: MonitorEventRow
    let artworkStore: ApplicationArtworkStore

    var body: some View {
        let flow = row.event.flow
        HStack(spacing: RiftDesign.Spacing.s) {
            Text(row.event.occurredAt.formatted(date: .omitted, time: .standard))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .leading)
            RiftDecisionBadge(decision: row.decision)
            ApplicationNameText(
                identity: flow.sourceAppIdentity ?? flow.sourceProcessIdentity,
                fallback: MonitorQuery.applicationLabel(row),
                artworkStore: artworkStore
            )
            .lineLimit(1)
            .frame(minWidth: 90, maxWidth: 180, alignment: .leading)
            Image(systemName: flow.direction == .incoming ? "arrow.left" : "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityLabel(flow.direction == .incoming ? "from" : "to")
            Text(MonitorQuery.endpointLabel(row))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(row.event.outcome == .blocked ? row.decision.color : Color.primary)
            Spacer(minLength: RiftDesign.Spacing.s)
            Text(MonitorQuery.protocolLabel(row))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
