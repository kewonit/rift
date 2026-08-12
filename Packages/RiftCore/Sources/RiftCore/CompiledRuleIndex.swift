import Foundation

private struct ProcessPair: Sendable, Hashable {
    let app: ProcessIdentity
    let helper: ProcessIdentity
}

private struct IPBucketKey: Sendable, Hashable {
    let family: IPAddress.Family
    let firstByte: UInt8
}

private struct IPIndexEntry: Sendable {
    let ruleID: UUID
    let interval: IPInterval
}

struct CompiledRuleIndex: Sendable {
    private let rulesByID: [UUID: Rule]

    private let anyProcess: [UUID]
    private let exactProcess: [ProcessIdentity: [UUID]]
    private let processPairs: [ProcessPair: [UUID]]

    private let anyProtocol: [UUID]
    private let tcp: [UUID]
    private let udp: [UUID]

    private let unprofiled: [UUID]
    private let profiles: [UUID: [UUID]]

    private let anyEndpoint: [UUID]
    private let exactHostnames: [String: [UUID]]
    private let domains: [String: [UUID]]
    private let endpointClasses: [EndpointClass: [UUID]]
    private let ipBuckets: [IPBucketKey: [IPIndexEntry]]
    private let spanningIPEntries: [IPAddress.Family: [IPIndexEntry]]

    init(rules: [Rule]) {
        var rulesByID: [UUID: Rule] = [:]
        var anyProcess: [UUID] = []
        var exactProcess: [ProcessIdentity: [UUID]] = [:]
        var processPairs: [ProcessPair: [UUID]] = [:]
        var anyProtocol: [UUID] = []
        var tcp: [UUID] = []
        var udp: [UUID] = []
        var unprofiled: [UUID] = []
        var profiles: [UUID: [UUID]] = [:]
        var anyEndpoint: [UUID] = []
        var exactHostnames: [String: [UUID]] = [:]
        var domains: [String: [UUID]] = [:]
        var endpointClasses: [EndpointClass: [UUID]] = [:]
        var ipBuckets: [IPBucketKey: [IPIndexEntry]] = [:]
        var spanningIPEntries: [IPAddress.Family: [IPIndexEntry]] = [:]

        for rule in rules {
            rulesByID[rule.id] = rule
            switch rule.process {
            case .anyProcess:
                anyProcess.append(rule.id)
            case .exact(let identity):
                exactProcess[identity, default: []].append(rule.id)
            case .appViaHelper(let app, let helper):
                processPairs[ProcessPair(app: app, helper: helper), default: []].append(rule.id)
            }
            switch rule.transportProtocol {
            case .anySupportedProtocol: anyProtocol.append(rule.id)
            case .tcp: tcp.append(rule.id)
            case .udp: udp.append(rule.id)
            }
            if let profileID = rule.profileID {
                profiles[profileID, default: []].append(rule.id)
            } else {
                unprofiled.append(rule.id)
            }
            switch rule.destination {
            case .anyEndpoint:
                anyEndpoint.append(rule.id)
            case .exactHostnameSet(let values):
                for value in values {
                    exactHostnames[value.ascii, default: []].append(rule.id)
                }
            case .domainSet(let values):
                for value in values {
                    domains[value.ascii, default: []].append(rule.id)
                }
            case .endpointClass(let value):
                endpointClasses[value, default: []].append(rule.id)
            case .ipSet(let values):
                for interval in values {
                    let lower = interval.lowerBound.bytes[0]
                    let upper = interval.upperBound.bytes[0]
                    let entry = IPIndexEntry(ruleID: rule.id, interval: interval)
                    if lower == upper {
                        let key = IPBucketKey(
                            family: interval.lowerBound.family,
                            firstByte: lower
                        )
                        ipBuckets[key, default: []].append(entry)
                    } else {
                        spanningIPEntries[interval.lowerBound.family, default: []].append(entry)
                    }
                }
            }
        }

        self.rulesByID = rulesByID
        self.anyProcess = anyProcess
        self.exactProcess = exactProcess
        self.processPairs = processPairs
        self.anyProtocol = anyProtocol
        self.tcp = tcp
        self.udp = udp
        self.unprofiled = unprofiled
        self.profiles = profiles
        self.anyEndpoint = anyEndpoint
        self.exactHostnames = exactHostnames
        self.domains = domains
        self.endpointClasses = endpointClasses
        self.ipBuckets = ipBuckets
        self.spanningIPEntries = spanningIPEntries
    }

    var indexedIPMembershipCount: Int {
        ipBuckets.values.reduce(0) { $0 + $1.count }
            + spanningIPEntries.values.reduce(0) { $0 + $1.count }
    }

    func candidates(flow: FlowDescriptor, context: MatchContext) -> [Rule] {
        var smallest = identityCandidates(flow: flow)
        let protocolCount = protocolCandidateCount(flow.transportProtocol)
        if protocolCount < smallest.count {
            smallest = protocolCandidates(flow.transportProtocol)
        }
        let profileCount = profileCandidateCount(context.activeProfileID)
        if profileCount < smallest.count {
            smallest = profileCandidates(context.activeProfileID)
        }
        // Every endpoint candidate includes the any-endpoint bucket. Avoid
        // materializing larger destination unions when another index already
        // gives a tighter bound.
        if flow.destinationEndpoint == nil || anyEndpoint.count < smallest.count {
            let destination = destinationCandidates(flow: flow)
            if destination.count < smallest.count {
                smallest = destination
            }
        }
        return smallest.compactMap { rulesByID[$0] }
    }

    private func identityCandidates(flow: FlowDescriptor) -> [UUID] {
        var result = anyProcess
        if let app = flow.sourceAppIdentity {
            result.append(contentsOf: exactProcess[app, default: []])
        }
        if let process = flow.sourceProcessIdentity, process != flow.sourceAppIdentity {
            result.append(contentsOf: exactProcess[process, default: []])
        }
        if let app = flow.sourceAppIdentity, let helper = flow.sourceProcessIdentity {
            result.append(contentsOf: processPairs[
                ProcessPair(app: app, helper: helper),
                default: []
            ])
        }
        return result
    }

    private func protocolCandidates(_ value: TransportProtocol) -> [UUID] {
        switch value {
        case .tcp: anyProtocol + tcp
        case .udp: anyProtocol + udp
        case .unsupported: []
        }
    }

    private func protocolCandidateCount(_ value: TransportProtocol) -> Int {
        switch value {
        case .tcp: anyProtocol.count + tcp.count
        case .udp: anyProtocol.count + udp.count
        case .unsupported: 0
        }
    }

    private func profileCandidates(_ activeProfileID: UUID?) -> [UUID] {
        guard let activeProfileID else { return unprofiled }
        return unprofiled + profiles[activeProfileID, default: []]
    }

    private func profileCandidateCount(_ activeProfileID: UUID?) -> Int {
        unprofiled.count + (activeProfileID.map { profiles[$0, default: []].count } ?? 0)
    }

    private func destinationCandidates(flow: FlowDescriptor) -> [UUID] {
        guard let endpoint = flow.destinationEndpoint else { return [] }
        var result = anyEndpoint
        var included = Set(result)

        let key = IPBucketKey(family: endpoint.address.family, firstByte: endpoint.address.bytes[0])
        for entry in ipBuckets[key, default: []]
        where entry.interval.contains(endpoint.address) && included.insert(entry.ruleID).inserted {
            result.append(entry.ruleID)
        }
        for entry in spanningIPEntries[endpoint.address.family, default: []]
        where entry.interval.contains(endpoint.address) && included.insert(entry.ruleID).inserted {
            result.append(entry.ruleID)
        }

        if flow.direction == .outgoing, let hostname = flow.observedHostname {
            appendUnique(exactHostnames[hostname.ascii, default: []], to: &result, included: &included)
            let labels = hostname.ascii.split(separator: ".")
            for offset in labels.indices {
                let suffix = labels[offset...].joined(separator: ".")
                appendUnique(domains[suffix, default: []], to: &result, included: &included)
            }
        }
        for endpointClass in endpoint.classes {
            appendUnique(
                endpointClasses[endpointClass, default: []],
                to: &result,
                included: &included
            )
        }
        return result
    }

    private func appendUnique(
        _ values: [UUID],
        to result: inout [UUID],
        included: inout Set<UUID>
    ) {
        for value in values where included.insert(value).inserted {
            result.append(value)
        }
    }
}
