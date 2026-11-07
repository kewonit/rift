import RiftCore
import Foundation

public enum MonitorHierarchyBuilder {
    public static func build(
        _ rows: [MonitorDisplayRow],
        lens: MonitorLens,
        coverages: [String: MonitorRuleCoverage],
        displayNames: [ProcessIdentity: String] = [:]
    ) -> [MonitorHierarchyNode] {
        // Each row's grouping path and rule seed are computed once, not once per level.
        let entries = rows.map { row in
            Entry(row: row, path: path(for: row, lens: lens, displayNames: displayNames), seed: MonitorExactRuleSeed.make(from: row.source))
        }
        return group(entries, depth: 0, parentID: lens.rawValue, coverages: coverages)
    }

    public static func node(
        forEventID eventID: String,
        in nodes: [MonitorHierarchyNode]
    ) -> MonitorHierarchyNode? {
        for node in nodes {
            if node.eventID == eventID { return node }
            if let children = node.children,
               let match = self.node(forEventID: eventID, in: children) {
                return match
            }
        }
        return nil
    }

    public static func node(
        withID id: String,
        in nodes: [MonitorHierarchyNode]
    ) -> MonitorHierarchyNode? {
        for node in nodes {
            if node.id == id { return node }
            if let children = node.children,
               let match = self.node(withID: id, in: children) {
                return match
            }
        }
        return nil
    }

    private struct Entry {
        let row: MonitorDisplayRow
        let path: [Component]
        let seed: MonitorExactRuleSeed?
    }

    private struct Component: Hashable {
        let kind: MonitorHierarchyKind
        let key: String
        let title: String
        let subtitle: String?
    }

    private static func group(
        _ entries: [Entry],
        depth: Int,
        parentID: String,
        coverages: [String: MonitorRuleCoverage]
    ) -> [MonitorHierarchyNode] {
        guard entries.contains(where: { depth < $0.path.count }) else {
            return entries.map { leaf($0, parentID: parentID, coverages: coverages) }
        }
        var order: [Component] = []
        var grouped: [Component: [Entry]] = [:]
        for entry in entries {
            guard depth < entry.path.count else { continue }
            let component = entry.path[depth]
            if grouped[component] == nil { order.append(component) }
            grouped[component, default: []].append(entry)
        }
        return order.map { component in
            let memberEntries = grouped[component] ?? []
            let members = memberEntries.map(\.row)
            let id = parentID + "/" + component.kind.rawValue + ":" + escape(component.key)
            let children = group(memberEntries, depth: depth + 1, parentID: id, coverages: coverages)
            let seeds = memberEntries.compactMap(\.seed)
            let exactSeed = seeds.count == members.count
                && seeds.dropFirst().allSatisfy { $0 == seeds.first } ? seeds.first : nil
            return MonitorHierarchyNode(
                id: id,
                kind: component.kind,
                title: DisplaySanitizer.plainText(component.title),
                subtitle: component.subtitle.map { DisplaySanitizer.plainText($0) },
                aggregate: MonitorAggregate(rows: members.map(\.source)),
                ruleCoverage: MonitorCoverageEvaluator.aggregate(members.map {
                    coverages[$0.id] ?? MonitorRuleCoverage(state: .noRule)
                }),
                eventIDs: Set(members.map(\.id)),
                eventID: nil,
                exactRuleSeed: exactSeed,
                ruleSeedEventID: exactSeed == nil ? nil : members.first?.id,
                presentationIdentity: presentationIdentity(component.kind, members.first),
                children: children
            )
        }
    }

    private static func leaf(
        _ entry: Entry,
        parentID: String,
        coverages: [String: MonitorRuleCoverage]
    ) -> MonitorHierarchyNode {
        let row = entry.row
        let exactSeed = entry.seed
        return MonitorHierarchyNode(
            id: parentID + "/flow:" + row.id,
            kind: .flow,
            title: MonitorQuery.endpointLabel(row.source),
            subtitle: row.source.event.occurredAt.formatted(
                date: .omitted, time: .standard
            ),
            aggregate: MonitorAggregate(rows: [row.source]),
            ruleCoverage: coverages[row.id] ?? MonitorRuleCoverage(state: .noRule),
            eventIDs: [row.id],
            eventID: row.id,
            exactRuleSeed: exactSeed,
            ruleSeedEventID: exactSeed == nil ? nil : row.id,
            presentationIdentity: nil,
            children: nil
        )
    }

    private static func path(
        for row: MonitorDisplayRow,
        lens: MonitorLens,
        displayNames: [ProcessIdentity: String]
    ) -> [Component] {
        let source = row.source
        let flow = source.event.flow
        let identity = flow.sourceAppIdentity ?? flow.sourceProcessIdentity
        let app = identity.flatMap { displayNames[$0] } ?? MonitorQuery.applicationLabel(source)
        let appKey = String(reflecting: identity)
        let appComponent = Component(
            kind: .application, key: appKey, title: app, subtitle: nil
        )
        let helper = helperComponent(flow)
        switch lens {
        case .application:
            return [appComponent] + helper + hostnameComponents(flow, subtitle: routeSubtitle(flow))
        case .hostname:
            return hostnameComponents(flow) + [appComponent] + helper
        }
    }

    private static func hostnameComponents(
        _ flow: FlowDescriptor,
        subtitle: String? = nil
    ) -> [Component] {
        if flow.metadataConfidence.contains(.observedHostname),
           let hostname = flow.observedHostname {
            return [Component(
                kind: .hostname,
                key: "observed-hostname:" + hostname.ascii,
                title: hostname.ascii,
                subtitle: subtitle
            )]
        }
        let unavailable = Component(
            kind: .hostname,
            key: "hostname-unavailable",
            title: "Hostname unavailable",
            subtitle: subtitle
        )
        guard let endpoint = flow.destinationEndpoint else { return [unavailable] }
        return [unavailable, Component(
            kind: .address,
            key: "destination-address:" + endpoint.address.description,
            title: endpoint.address.description,
            subtitle: "IP address"
        )]
    }

    private static func helperComponent(_ flow: FlowDescriptor) -> [Component] {
        guard let app = flow.sourceAppIdentity,
              let process = flow.sourceProcessIdentity,
              app != process else { return [] }
        return [Component(
            kind: .helper,
            key: String(reflecting: process),
            title: MonitorQuery.identityLabel(process),
            subtitle: "Helper"
        )]
    }

    private static func presentationIdentity(
        _ kind: MonitorHierarchyKind,
        _ row: MonitorDisplayRow?
    ) -> ProcessIdentity? {
        guard let flow = row?.source.event.flow else { return nil }
        if kind == .application { return flow.sourceAppIdentity ?? flow.sourceProcessIdentity }
        if kind == .helper { return flow.sourceProcessIdentity }
        return nil
    }

    /// Says where a connection went when it isn't the ordinary case of an
    /// outgoing connection to the internet.
    private static func routeSubtitle(_ flow: FlowDescriptor) -> String? {
        let classes = flow.destinationEndpoint?.classes ?? []
        let locality: String? =
            if classes.contains(.loopback) { "This Mac" }
            else if classes.contains(.bonjour) { "Bonjour" }
            else if classes.contains(.broadcast) { "Broadcast" }
            else if classes.contains(.multicast) { "Multicast" }
            else if classes.contains(.localNetwork) { "Local network" }
            else if classes.contains(.linkLocal) { "Local network" }
            else { nil }
        let parts = [flow.direction == .incoming ? "Incoming" : nil, locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "/", with: "\\/")
    }
}
