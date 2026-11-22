import Foundation
import RiftCore

/// Turns a `.lsrules` file into Rift rules for the Rules page, and its
/// blocked destinations into blocklist entries for Settings › Blocklists.
///
/// Rift identifies apps by their code signature, so each process path or
/// code ID is looked up on this Mac. A rule Rift can't express the same way
/// is skipped and counted rather than widened or narrowed: other protocols
/// such as ICMP, DNS-server and packet-filter destinations, port lists, and
/// rules for other accounts.
public enum LSRulesConverter {
    public struct Conversion: Sendable, Equatable {
        public let payload: ConfigurationArchivePayload
        /// Rules whose app isn't on this Mac.
        public let missingApps: Int
        /// Rules Rift can't express.
        public let unsupported: Int
        /// High-priority rules Rift adds at normal priority.
        public let lowered: Int
        /// Destinations under the file's blocked lists, for Blocklists.
        public let blockedDestinations: Int

        /// What else the import does, for the confirmation.
        public var notices: [String] {
            var parts: [String] = []
            if missingApps > 0 {
                parts.append(missingApps == 1
                    ? "1 rule is skipped because its app isn’t on this Mac."
                    : "\(missingApps) rules are skipped because their apps aren’t on this Mac.")
            }
            if unsupported > 0 {
                parts.append(unsupported == 1
                    ? "1 rule is skipped because Rift can’t apply it as written, such as one for ICMP or another account."
                    : "\(unsupported) rules are skipped because Rift can’t apply them as written, such as ones for ICMP or another account.")
            }
            if lowered > 0 {
                parts.append(lowered == 1
                    ? "1 high-priority rule is added at normal priority."
                    : "\(lowered) high-priority rules are added at normal priority.")
            }
            if blockedDestinations > 0 {
                parts.append("To block the file’s \(blockedDestinations) listed destinations too, import it in Settings › Blocklists.")
            }
            return parts
        }
    }

    public typealias Resolver = @Sendable (LSRulesFile.Process) -> ProcessIdentity?

    public static func convert(
        _ file: LSRulesFile,
        fileName: String,
        lineageID: UUID,
        resolve: Resolver,
        suffixes: PublicSuffixList = .shared,
        now: Date
    ) -> Conversion {
        let groupName = (try? PolicyDefinitionValidator.name(file.name ?? fileName))
            ?? (try? PolicyDefinitionValidator.name(fileName)) ?? "Imported rules"
        let group = LocalRuleGroup(
            id: UUID(), name: groupName, note: file.description ?? "",
            isEnabled: true, createdAt: now, modifiedAt: now
        )
        var rules: [Rule] = []
        var missingApps = 0
        var unsupported = 0
        var lowered = 0
        var cache: [LSRulesFile.Process: ProcessIdentity?] = [:]
        func identity(_ process: LSRulesFile.Process) -> ProcessIdentity? {
            if let cached = cache[process] { return cached }
            let resolved = resolve(process)
            cache[process] = resolved
            return resolved
        }
        for source in file.rules {
            switch processCondition(source, identity: identity) {
            case .missing:
                missingApps += 1
            case .unsupported:
                unsupported += 1
            case .resolved(let process):
                guard let made = try? makeRules(
                    source, process: process, group: group.id, lineageID: lineageID,
                    suffixes: suffixes, now: now
                ) else {
                    unsupported += 1
                    continue
                }
                if made.lowered { lowered += 1 }
                rules += made.rules
            }
        }
        let blocked = file.deniedHosts.count + file.deniedDomains.count + file.deniedAddresses.count
        return Conversion(
            payload: ConfigurationArchivePayload(
                baseOperationMode: .silentAllow, activeProfileID: nil, rules: rules,
                localGroups: rules.isEmpty ? [] : [group], profiles: [], blocklists: []
            ),
            missingApps: missingApps,
            unsupported: unsupported,
            lowered: lowered,
            blockedDestinations: blocked
        )
    }

    /// The file's blocked destinations, for a blocklist: its blocked lists,
    /// plus rules that block a list of destinations for every app. Anything
    /// else in the file means it's a rule group, not a blocklist.
    public static func blocklistEntries(_ file: LSRulesFile) throws -> [BlocklistEntry] {
        var entries: [BlocklistEntry] = []
        var otherRules = 0
        func add(hosts: [String], domains: [String], addresses: [String]) throws {
            for host in hosts {
                guard let name = try? DomainName.converting(host) else { throw LSRulesFileError.malformedEntry(host) }
                entries.append(.domain(name))
            }
            for domain in domains {
                guard let name = try? DomainName.converting(domain) else {
                    throw LSRulesFileError.malformedEntry(domain)
                }
                entries.append(.domainAndSubdomains(name))
            }
            for address in addresses.flatMap({ $0.split(separator: ",").map(String.init) }) {
                guard case .ipSet(let values) = try? DestinationEditorParser.parse(
                    address, domainsIncludeChildren: false
                ) else { throw LSRulesFileError.malformedEntry(address) }
                entries += values.map(BlocklistEntry.address)
            }
            guard entries.count <= BlocklistParser.maximumEntries else {
                throw LSRulesFileError.tooManyRules
            }
        }
        try add(hosts: file.deniedHosts, domains: file.deniedDomains, addresses: file.deniedAddresses)
        for rule in file.rules where !rule.disabled {
            guard rule.action == "deny", rule.process == .any, rule.via == nil,
                  rule.ports == "any", rule.transport == "any", rule.direction == "outgoing",
                  rule.unknownKeys.isEmpty else {
                otherRules += 1
                continue
            }
            switch rule.remote {
            case .hosts(let hosts): try add(hosts: hosts, domains: [], addresses: [])
            case .domains(let domains): try add(hosts: [], domains: domains, addresses: [])
            case .addresses(let text): try add(hosts: [], domains: [], addresses: [text])
            case .any, .named: otherRules += 1
            }
        }
        guard otherRules == 0 else { throw LSRulesFileError.hasOtherRules(otherRules) }
        guard !entries.isEmpty else { throw LSRulesFileError.noBlockedDestinations }
        return entries
    }

    private enum ProcessResult {
        case resolved(ProcessCondition)
        case missing
        case unsupported
    }

    private static func processCondition(
        _ rule: LSRulesFile.Rule,
        identity: (LSRulesFile.Process) -> ProcessIdentity?
    ) -> ProcessResult {
        guard rule.unknownKeys.isEmpty else { return .unsupported }
        switch (rule.process, rule.via) {
        case (.any, nil):
            return .resolved(.anyProcess)
        case (.any, .some):
            // Rift ties a helper to the app that started it.
            return .unsupported
        case (let app, nil):
            guard let resolved = identity(app) else { return .missing }
            return .resolved(.exact(resolved))
        case (let app, .some(let helper)):
            guard let resolvedApp = identity(app), let resolvedHelper = identity(helper) else { return .missing }
            return .resolved(resolvedApp == resolvedHelper
                ? .exact(resolvedApp) : .appViaHelper(app: resolvedApp, helper: resolvedHelper))
        }
    }

    private struct MadeRules {
        let rules: [Rule]
        let lowered: Bool
    }

    private struct Unsupported: Error {}

    private static func makeRules(
        _ source: LSRulesFile.Rule,
        process: ProcessCondition,
        group: UUID,
        lineageID: UUID,
        suffixes: PublicSuffixList,
        now: Date
    ) throws -> MadeRules {
        let action: FilterAction
        switch source.action {
        case "allow": action = .allow
        case "deny": action = .deny
        case "ask": action = .ask
        default: throw Unsupported()
        }
        let direction: DirectionCondition
        switch source.direction {
        case "outgoing": direction = .outgoing
        case "incoming": direction = .incoming
        default: throw Unsupported()
        }
        let transport: ProtocolCondition
        switch source.transport {
        case "any": transport = .anySupportedProtocol
        case "tcp", "6": transport = .tcp
        case "udp", "17": transport = .udp
        default: throw Unsupported()
        }
        let port: PortRange?
        if source.ports == "any" || source.ports.isEmpty {
            port = nil
        } else {
            let parts = source.ports.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count <= 2, let lower = UInt16(parts[0]),
                  let upper = UInt16(parts.count == 2 ? parts[1] : parts[0]) else { throw Unsupported() }
            port = try PortRange(lower, upper)
        }
        let destinations = try destinations(source.remote, direction: direction, suffixes: suffixes)
        let notes = String(source.notes.unicodeScalars.prefix(PolicyLimits.maximumNotesScalars))
        var lowered = false
        let rules = try destinations.map { destination -> Rule in
            func rule(_ priority: RulePriority) throws -> Rule {
                try Rule(
                    id: UUID(), lineageID: lineageID, revision: 1, action: .filter(action),
                    priority: priority, process: process, destination: destination,
                    transportProtocol: transport, port: port, direction: direction,
                    owner: .authorizedUser, localGroupID: group, isEnabled: !source.disabled,
                    reviewState: .unreviewed, source: .imported, notes: notes,
                    createdAt: now, modifiedAt: now
                )
            }
            guard source.priority == "high" else { return try rule(.normal) }
            // Rift raises priority only for an Allow for one app to an exact
            // destination, so other high-priority rules come in as normal.
            if let elevated = try? rule(.elevatedUser) { return elevated }
            lowered = true
            return try rule(.normal)
        }
        return MadeRules(rules: rules, lowered: lowered)
    }

    /// One condition per chunk of destinations, since a rule holds at most
    /// `maximumDestinationMembers`.
    private static func destinations(
        _ remote: LSRulesFile.Remote,
        direction: DirectionCondition,
        suffixes: PublicSuffixList
    ) throws -> [DestinationCondition] {
        func chunks<T>(_ values: [T]) -> [[T]] {
            stride(from: 0, to: values.count, by: PolicyLimits.maximumDestinationMembers).map {
                Array(values[$0..<min($0 + PolicyLimits.maximumDestinationMembers, values.count)])
            }
        }
        switch remote {
        case .any:
            return [.anyEndpoint]
        case .named(let name):
            switch name {
            case "local-net": return [.endpointClass(.localNetwork)]
            case "multicast": return [.endpointClass(.multicast)]
            case "broadcast": return [.endpointClass(.broadcast)]
            case "bonjour": return [.endpointClass(.bonjour)]
            default: throw Unsupported()
            }
        case .hosts(let hosts):
            // Names are known only for outgoing connections.
            guard direction == .outgoing, !hosts.isEmpty else { throw Unsupported() }
            let names = try hosts.map { try DomainName.converting($0) }
            return try chunks(names).map { try .normalizedExactHostnameSet($0) }
        case .domains(let domains):
            guard direction == .outgoing, !domains.isEmpty else { throw Unsupported() }
            let names = try domains.map { try DomainName.converting($0) }
            guard !names.contains(where: suffixes.coversWholeRegistry) else { throw Unsupported() }
            return try chunks(names).map { try .normalizedDomainSet($0) }
        case .addresses(let text):
            let tokens = text.split(separator: ",").map(String.init)
            guard !tokens.isEmpty else { throw Unsupported() }
            return try chunks(tokens).map {
                try DestinationEditorParser.parse($0.joined(separator: ","), domainsIncludeChildren: false)
            }
        }
    }
}
