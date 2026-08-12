import AbyssCore
import Foundation

public enum MonitorHierarchyBuilder {
    public static func build(
        _ rows: [MonitorDisplayRow],
        lens: MonitorLens,
        coverages: [String: MonitorRuleCoverage]
    ) -> [MonitorHierarchyNode] {
        group(rows, depth: 0, parentID: lens.rawValue, lens: lens, coverages: coverages)
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

    private struct Component: Hashable {
        let kind: MonitorHierarchyKind
        let key: String
        let title: String
        let subtitle: String?
    }

    private static func group(
        _ rows: [MonitorDisplayRow],
        depth: Int,
        parentID: String,
        lens: MonitorLens,
        coverages: [String: MonitorRuleCoverage]
    ) -> [MonitorHierarchyNode] {
        let paths = rows.map { path(for: $0, lens: lens) }
        guard paths.contains(where: { depth < $0.count }) else {
            return rows.map { leaf($0, parentID: parentID, coverages: coverages) }
        }
        var order: [Component] = []
        var grouped: [Component: [MonitorDisplayRow]] = [:]
        for (index, row) in rows.enumerated() {
            let path = paths[index]
            guard depth < path.count else { continue }
            let component = path[depth]
            if grouped[component] == nil { order.append(component) }
            grouped[component, default: []].append(row)
        }
        return order.map { component in
            let members = grouped[component] ?? []
            let id = parentID + "/" + component.kind.rawValue + ":" + escape(component.key)
            let children = group(
                members, depth: depth + 1, parentID: id, lens: lens,
                coverages: coverages
            )
            let seeds = members.compactMap { MonitorExactRuleSeed.make(from: $0.source) }
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
                eventID: nil,
                exactRuleSeed: exactSeed,
                ruleSeedEventID: exactSeed == nil ? nil : members.first?.id,
                presentationIdentity: presentationIdentity(component.kind, members.first),
                children: children
            )
        }
    }

    private static func leaf(
        _ row: MonitorDisplayRow,
        parentID: String,
        coverages: [String: MonitorRuleCoverage]
    ) -> MonitorHierarchyNode {
        let exactSeed = MonitorExactRuleSeed.make(from: row.source)
        return MonitorHierarchyNode(
            id: parentID + "/flow:" + row.id,
            kind: .flow,
            title: MonitorQuery.endpointLabel(row.source),
            subtitle: row.source.event.occurredAt.formatted(
                date: .omitted, time: .standard
            ),
            aggregate: MonitorAggregate(rows: [row.source]),
            ruleCoverage: coverages[row.id] ?? MonitorRuleCoverage(state: .noRule),
            eventID: row.id,
            exactRuleSeed: exactSeed,
            ruleSeedEventID: exactSeed == nil ? nil : row.id,
            presentationIdentity: nil,
            children: nil
        )
    }

    private static func path(
        for row: MonitorDisplayRow,
        lens: MonitorLens
    ) -> [Component] {
        let source = row.source
        let flow = source.event.flow
        let app = MonitorQuery.applicationLabel(source)
        let appKey = String(reflecting: flow.sourceAppIdentity ?? flow.sourceProcessIdentity)
        let appComponent = Component(
            kind: .application, key: appKey, title: app, subtitle: nil
        )
        let helper = helperComponent(flow)
        switch lens {
        case .application:
            return [appComponent] + helper + [routeComponent(flow)]
                + hostnameComponents(flow)
        case .hostname:
            return hostnameComponents(flow) + [appComponent] + helper
        case .location:
            return locationComponents(row) + [appComponent] + helper
        }
    }

    private static func hostnameComponents(_ flow: FlowDescriptor) -> [Component] {
        if flow.metadataConfidence.contains(.observedHostname),
           let hostname = flow.observedHostname {
            return [Component(
                kind: .hostname,
                key: "observed-hostname:" + hostname.ascii,
                title: hostname.ascii,
                subtitle: nil
            )]
        }
        let unavailable = Component(
            kind: .hostname,
            key: "hostname-unavailable",
            title: "Hostname unavailable",
            subtitle: nil
        )
        guard let endpoint = flow.destinationEndpoint else { return [unavailable] }
        return [unavailable, Component(
            kind: .address,
            key: "destination-address:" + endpoint.address.description,
            title: endpoint.address.description,
            subtitle: "IP address"
        )]
    }

    private static func locationComponents(_ row: MonitorDisplayRow) -> [Component] {
        switch row.geography {
        case .located(let value):
            let countryKey = value.countryCode.isEmpty ? "unknown-country" : value.countryCode
            var components = [Component(
                kind: .country,
                key: countryKey,
                title: value.countryName,
                subtitle: value.countryCode.isEmpty ? nil : value.countryCode
            )]
            let locality = value.city.isEmpty ? value.region : value.city
            if !locality.isEmpty {
                components.append(Component(
                    kind: .city,
                    key: value.region + "|" + value.city,
                    title: locality,
                    subtitle: value.city.isEmpty || value.region.isEmpty ? nil : value.region
                ))
            }
            return components
        case .nonGeographic, .notFound:
            return [Component(
                kind: .nonGeographic,
                key: row.geography.displayName,
                title: row.geography.displayName,
                subtitle: "Not plotted"
            )]
        }
    }

    private static func helperComponent(_ flow: FlowDescriptor) -> [Component] {
        guard let app = flow.sourceAppIdentity,
              let process = flow.sourceProcessIdentity,
              app != process else { return [] }
        return [Component(
            kind: .helper,
            key: String(reflecting: process),
            title: MonitorQuery.identityLabel(process),
            subtitle: "Helper process"
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

    private static func routeComponent(_ flow: FlowDescriptor) -> Component {
        let direction = flow.direction == .outgoing ? "Outgoing" : "Incoming"
        let locality: String
        guard let classes = flow.destinationEndpoint?.classes else {
            return Component(
                kind: .route,
                key: direction + "Unknown locality",
                title: direction + " • Unknown locality",
                subtitle: nil
            )
        }
        if classes.contains(.loopback) { locality = "Loopback" }
        else if classes.contains(.bonjour) { locality = "Bonjour" }
        else if classes.contains(.broadcast) { locality = "Broadcast" }
        else if classes.contains(.multicast) { locality = "Multicast" }
        else if classes.contains(.localNetwork) { locality = "Local network" }
        else if classes.contains(.linkLocal) { locality = "Link-local" }
        else { locality = "Internet" }
        return Component(
            kind: .route,
            key: direction + locality,
            title: direction + " • " + locality,
            subtitle: nil
        )
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "/", with: "\\/")
    }
}
