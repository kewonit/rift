import Foundation
import RiftCore

/// Writes Rift rules as a `.lsrules` rule group file, the JSON format other
/// Mac firewalls import and publish. It's the counterpart of
/// `LSRulesConverter`, with the same rule: a rule the format can't express
/// exactly is skipped and counted, never widened. That leaves out temporary
/// rules, rules for one profile or for system processes, rules that hide
/// connections or notify, and apps the format can't name.
public enum LSRulesWriter {
    public struct Export: Sendable, Equatable {
        public let data: Data
        /// Rift rules written to the file.
        public let exported: Int
        /// Rift rules left out.
        public let skipped: Int

        /// What happened, for the Rules page.
        public var summary: String {
            let written = String(localized: "Exported \(exported) rules.", bundle: .module)
            guard skipped > 0 else { return written }
            let left = String(localized: "\(skipped) rules were skipped because the .lsrules format can’t express them, such as temporary rules, rules for one profile, or rules for system processes.", bundle: .module)
            return "\(written) \(left)"
        }
    }

    public enum ExportError: Error, Sendable, Equatable {
        case nothingToExport
    }

    /// The executable path for code that has no team to name it by, such as
    /// an app that comes with macOS. Nil when Rift can't find it.
    public typealias PathResolver = @Sendable (ProcessIdentity) -> String?

    public static func export(
        _ rules: [Rule],
        name: String,
        description: String? = nil,
        path: PathResolver
    ) throws -> Export {
        var written: [[String: Any]] = []
        var exported = 0
        var skipped = 0
        for rule in rules {
            guard let entries = entries(for: rule, path: path) else {
                skipped += 1
                continue
            }
            written += entries
            exported += 1
        }
        guard exported > 0 else { throw ExportError.nothingToExport }
        var root: [String: Any] = ["name": name.withoutControlCharacters, "rules": written]
        if let description, !description.isEmpty { root["description"] = description.withoutControlCharacters }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return Export(data: data, exported: exported, skipped: skipped)
    }

    /// One entry for the rule, or two for a rule in both directions, which
    /// the format writes as one rule per direction. Nil when it can't be
    /// written the same way.
    static func entries(for rule: Rule, path: PathResolver) -> [[String: Any]]? {
        guard ConfigurationArchiveCodec.isShareable(rule), rule.expiresAt == nil, rule.profileID == nil,
              rule.owner == .authorizedUser, case .filter(let action) = rule.action,
              let process = process(rule.process, path: path),
              let remote = remote(rule.destination) else { return nil }
        var entry: [String: Any] = ["action": action.rawValue]
        entry.merge(process) { first, _ in first }
        entry.merge(remote) { first, _ in first }
        switch rule.transportProtocol {
        case .tcp: entry["protocol"] = "tcp"
        case .udp: entry["protocol"] = "udp"
        case .anySupportedProtocol: break
        }
        if let port = rule.port {
            entry["ports"] = port.lowerBound == port.upperBound
                ? "\(port.lowerBound)" : "\(port.lowerBound)-\(port.upperBound)"
        }
        if rule.priority == .elevatedUser { entry["priority"] = "high" }
        if !rule.isEnabled { entry["disabled"] = true }
        if !rule.notes.isEmpty { entry["notes"] = rule.notes }
        let directions: [String] = switch rule.direction {
        case .outgoing: ["outgoing"]
        case .incoming: ["incoming"]
        case .bidirectional: ["outgoing", "incoming"]
        }
        // Names are known only for outgoing connections, so an incoming rule
        // for a name couldn't be read back the same way.
        if directions.contains("incoming"), entry["remote-hosts"] != nil || entry["remote-domains"] != nil {
            return nil
        }
        return directions.map { direction in
            var copy = entry
            copy["direction"] = direction
            return copy
        }
    }

    private static func process(_ condition: ProcessCondition, path: PathResolver) -> [String: Any]? {
        switch condition {
        case .anyProcess: return ["process": "any"]
        case .exact(let identity): return name(identity, path: path).map { ["process": $0] }
        // `via` takes a helper's path, which Rift's code identities don't carry.
        case .appViaHelper: return nil
        }
    }

    /// A code ID for a team's app, `identifier.TEAMID/bundle.id`, or the
    /// executable's path for an app that comes with macOS. Ad hoc, unsigned
    /// and other-certificate code is matched by a hash the format can't hold.
    static func name(_ identity: ProcessIdentity, path: PathResolver) -> String? {
        switch identity {
        case .developerID(let code), .appStore(let code):
            guard let team = code.teamIdentifier, !team.isEmpty else { return nil }
            return "identifier.\(team)/\(code.signingIdentifier)"
        case .applePlatform:
            return path(identity).flatMap { $0.hasPrefix("/") ? $0 : nil }
        case .otherSigner, .adHoc, .unsigned:
            return nil
        }
    }

    private static func remote(_ destination: DestinationCondition) -> [String: Any]? {
        switch destination {
        case .anyEndpoint: return ["remote": "any"]
        case .exactHostnameSet(let names): return ["remote-hosts": names.map(\.ascii)]
        case .domainSet(let names): return ["remote-domains": names.map(\.ascii)]
        case .ipSet(let intervals): return ["remote-addresses": intervals.map(\.description).joined(separator: ", ")]
        case .endpointClass(let value):
            switch value {
            case .localNetwork: return ["remote": "local-net"]
            case .multicast: return ["remote": "multicast"]
            case .broadcast: return ["remote": "broadcast"]
            case .bonjour: return ["remote": "bonjour"]
            case .loopback, .linkLocal: return nil
            }
        }
    }
}
