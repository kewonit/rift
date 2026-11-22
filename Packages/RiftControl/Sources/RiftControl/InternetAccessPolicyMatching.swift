import Foundation
import RiftCore
import RiftIPC

/// One entry of a policy's comma-separated `Host`.
public enum InternetAccessPolicyHost: Sendable, Hashable {
    /// `sw-update.example.com`.
    case name(String)
    /// `*.example.com`, which also covers `example.com`, or any pattern with
    /// `*` in it, such as `myserver*.com`.
    case pattern(String)
    /// `=*.example.com`, which applies only when the person chooses exactly
    /// that domain.
    case exactDomain(String)
    /// `=*`, which applies only when the person chooses any destination.
    case anyDestination
    /// `*`, used only when nothing else describes the connection.
    case fallback
    case address(IPAddress)
    /// A range or CIDR block.
    case addresses(IPInterval)
    case localNetwork
    /// Something Rift can't match, such as `bpf`.
    case unsupported

    public init(_ text: String) {
        let value = text.lowercased()
        if value == "*" { self = .fallback; return }
        if value == "=*" { self = .anyDestination; return }
        if value == "local-net" { self = .localNetwork; return }
        // Packet-filter access isn't a connection Rift sees.
        if value == "bpf" { self = .unsupported; return }
        if value.hasPrefix("=*."), let domain = Self.normalizedName(String(value.dropFirst(3))) {
            self = .exactDomain(domain)
            return
        }
        if let address = try? IPAddress(value) { self = .address(address); return }
        if let interval = Self.interval(value) { self = .addresses(interval); return }
        if value.contains("*") {
            let labels = value.replacingOccurrences(of: "*", with: "a")
            self = Self.normalizedName(labels) == nil ? .unsupported : .pattern(value)
            return
        }
        self = Self.normalizedName(value).map { .name($0) } ?? .unsupported
    }

    private static func normalizedName(_ text: String) -> String? {
        guard !text.isEmpty, text.utf8.count <= 253 else { return nil }
        return (try? DomainName.converting(text))?.ascii
    }

    private static func interval(_ text: String) -> IPInterval? {
        let range = text.split(separator: "-", omittingEmptySubsequences: false)
        if range.count == 2, let lower = try? IPAddress(String(range[0])), let upper = try? IPAddress(String(range[1])) {
            return try? IPInterval(range: lower, upper)
        }
        let cidr = text.split(separator: "/", omittingEmptySubsequences: false)
        if cidr.count == 2, let address = try? IPAddress(String(cidr[0])), let length = Int(cidr[1]) {
            return try? IPInterval(cidr: address, prefixLength: length)
        }
        return nil
    }
}

/// The connection Rift wants a developer's words for.
public struct InternetAccessPolicyQuery: Sendable, Hashable {
    /// What the person is about to make a rule for, since a policy can
    /// describe a whole domain, or any destination, on its own.
    public enum Choice: Sendable, Hashable {
        case thisConnection
        case domain(String)
        case anyDestination
    }

    public let host: String?
    public let address: IPAddress?
    public let isLocalNetwork: Bool
    public let port: UInt16?
    public let transport: TransportProtocol
    public let isIncoming: Bool
    public var choice: Choice

    public init(
        host: String?,
        address: IPAddress?,
        isLocalNetwork: Bool,
        port: UInt16?,
        transport: TransportProtocol,
        isIncoming: Bool,
        choice: Choice = .thisConnection
    ) {
        self.host = host?.lowercased()
        self.address = address
        self.isLocalNetwork = isLocalNetwork
        self.port = port
        self.transport = transport
        self.isIncoming = isIncoming
        self.choice = choice
    }
}

extension InternetAccessPolicyQuery {
    public init(prompt: PromptRequest, choice: Choice = .thisConnection) {
        let endpoint = prompt.endpoint
        self.init(
            host: endpoint?.hostname?.ascii, address: endpoint?.address,
            isLocalNetwork: endpoint.map(Self.isLocal) ?? false, port: endpoint?.port,
            transport: prompt.transportProtocol, isIncoming: prompt.direction == .incoming, choice: choice
        )
    }

    /// For an incoming connection, the host is the one connecting in and the
    /// port is the one it reached on this Mac.
    public init(flow: FlowDescriptor) {
        let remote = flow.remoteEndpoint
        let observed = flow.metadataConfidence.contains(.observedHostname) ? flow.observedHostname : nil
        self.init(
            host: (observed ?? remote?.hostname)?.ascii, address: remote?.address,
            isLocalNetwork: remote.map(Self.isLocal) ?? false,
            port: flow.direction == .incoming ? flow.localEndpoint?.port : remote?.port,
            transport: flow.transportProtocol, isIncoming: flow.direction == .incoming
        )
    }

    private static func isLocal(_ endpoint: Endpoint) -> Bool {
        !endpoint.classes.isDisjoint(with: [.localNetwork, .linkLocal])
    }
}

/// What the developer says about one connection.
public struct DeveloperExplanation: Sendable, Hashable {
    public static let maximumDescriptions = 3

    /// The matching descriptions, most relevant first. Empty when the policy
    /// doesn't mention this connection.
    public let connections: [InternetAccessPolicy.Connection]

    public var describesConnection: Bool { !connections.isEmpty }

    /// What the developer says blocking it would break, if they said.
    public var denyConsequences: [String] {
        var seen: Set<String> = []
        return connections.compactMap(\.denyConsequences).filter { seen.insert($0).inserted }
    }
}

extension InternetAccessPolicy {
    /// The developer's descriptions for a connection, chosen as the published
    /// format says: a description for this exact host, domain choice or
    /// "any destination" choice wins on its own; otherwise every matching
    /// domain or address range, essential ones first; otherwise the `*`
    /// fallback, if there is one.
    public func explanation(for query: InternetAccessPolicyQuery) -> DeveloperExplanation {
        let candidates = connections.filter { $0.applies(to: query) }
        let exact = candidates.filter { connection in connection.hosts.contains { $0.isExactMatch(for: query) } }
        if !exact.isEmpty { return Self.explanation(exact) }
        let general = candidates.filter { connection in connection.hosts.contains { $0.isGeneralMatch(for: query) } }
        if !general.isEmpty { return Self.explanation(general) }
        return Self.explanation(candidates.filter { $0.hosts.contains(.fallback) })
    }

    private static func explanation(_ matches: [Connection]) -> DeveloperExplanation {
        let essential = matches.filter(\.isEssential)
        let others = matches.filter { !$0.isEssential }
        return DeveloperExplanation(connections: Array((essential + others).prefix(DeveloperExplanation.maximumDescriptions)))
    }
}

extension InternetAccessPolicy.Connection {
    func applies(to query: InternetAccessPolicyQuery) -> Bool {
        guard isIncoming == query.isIncoming else { return false }
        if let networkProtocol {
            switch (networkProtocol, query.transport) {
            case (.tcp, .tcp), (.udp, .udp): break
            case (.icmp, .unsupported(let number)) where number == 1 || number == 58: break
            default: return false
            }
        }
        guard !ports.isEmpty else { return true }
        guard let port = query.port else { return false }
        return ports.contains { $0.contains(port) }
    }
}

extension InternetAccessPolicyHost {
    func isExactMatch(for query: InternetAccessPolicyQuery) -> Bool {
        switch self {
        case .name(let name): query.host == name
        case .address(let address): query.address == address
        case .exactDomain(let domain): query.choice == .domain(domain)
        case .anyDestination: query.choice == .anyDestination
        default: false
        }
    }

    func isGeneralMatch(for query: InternetAccessPolicyQuery) -> Bool {
        switch self {
        case .pattern(let pattern):
            guard let host = query.host else { return false }
            if pattern.hasPrefix("*."), !pattern.dropFirst(2).contains("*"), host == pattern.dropFirst(2) { return true }
            return Self.glob(pattern, matches: host)
        case .addresses(let interval): return query.address.map(interval.contains) ?? false
        case .localNetwork: return query.isLocalNetwork
        default: return false
        }
    }

    /// `*` matches any run of characters, dots included. Patterns and names
    /// are short and bounded, so the simple backtracking walk is enough.
    static func glob(_ pattern: String, matches name: String) -> Bool {
        let pattern = Array(pattern.utf8)
        let name = Array(name.utf8)
        var p = 0
        var n = 0
        var star: Int?
        var resume = 0
        while n < name.count {
            if p < pattern.count, pattern[p] == UInt8(ascii: "*") {
                star = p
                resume = n
                p += 1
            } else if p < pattern.count, pattern[p] == name[n] {
                p += 1
                n += 1
            } else if let star {
                p = star + 1
                resume += 1
                n = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == UInt8(ascii: "*") { p += 1 }
        return p == pattern.count
    }
}
