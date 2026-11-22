import Foundation

public enum LSRulesFileError: Error, Sendable, Equatable {
    case notARulesFile
    case tooManyRules
    /// The file has rules besides blocked destinations, so it belongs on the
    /// Rules page rather than in Blocklists.
    case hasOtherRules(Int)
    case noBlockedDestinations
    /// A listed destination isn't a valid name, address or range.
    case malformedEntry(String)
}

/// A rule group file in the `.lsrules` JSON format, which other Mac firewalls
/// export and publish. `LSRulesWriter` writes them.
public struct LSRulesFile: Sendable, Equatable {
    public enum Process: Sendable, Hashable {
        case any
        /// The full path to an executable.
        case path(String)
        /// `identifier.TEAMID/bundle.id`.
        case codeID(team: String, identifier: String)
    }

    public enum Remote: Sendable, Equatable {
        case any
        case hosts([String])
        case domains([String])
        case addresses(String)
        /// `local-net`, `multicast`, `broadcast`, `bonjour`, `dns-servers`
        /// or `bpf`.
        case named(String)
    }

    public struct Rule: Sendable, Equatable {
        public let process: Process
        public let via: Process?
        public let action: String
        public let remote: Remote
        public let direction: String
        public let priority: String
        public let disabled: Bool
        public let ports: String
        public let transport: String
        public let notes: String
        /// Keys this rule has that Rift doesn't know, or whose values have the
        /// wrong type, either of which may change what it means.
        public let unknownKeys: [String]
    }

    public static let maximumRules = 20_000

    public let name: String?
    public let description: String?
    public let rules: [Rule]
    public let deniedHosts: [String]
    public let deniedDomains: [String]
    public let deniedAddresses: [String]

    /// Whether `data` looks like a rule group file rather than a plain
    /// blocklist or one of Rift's own files.
    public static func looksLikeRulesFile(_ data: Data) -> Bool {
        guard let first = data.first(where: { !" \t\r\n".utf8.contains($0) }), first == UInt8(ascii: "{"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard object["schemaVersion"] == nil, object["payload"] == nil else { return false }
        return object["rules"] is [Any] || object["denied-remote-domains"] != nil
            || object["denied-remote-hosts"] != nil || object["denied-remote-addresses"] != nil
    }

    public static func decode(_ data: Data) throws -> LSRulesFile {
        guard looksLikeRulesFile(data),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LSRulesFileError.notARulesFile
        }
        let rawRules = object["rules"] as? [Any] ?? []
        guard rawRules.count <= maximumRules else { throw LSRulesFileError.tooManyRules }
        return LSRulesFile(
            name: object["name"] as? String,
            description: object["description"] as? String,
            rules: rawRules.compactMap { ($0 as? [String: Any]).map(rule) },
            deniedHosts: strings(object["denied-remote-hosts"]),
            deniedDomains: strings(object["denied-remote-domains"]),
            deniedAddresses: strings(object["denied-remote-addresses"])
        )
    }

    private static let knownKeys: Set<String> = [
        "process", "via", "action", "remote", "remote-hosts", "remote-domains", "remote-addresses",
        "direction", "priority", "disabled", "ports", "protocol", "notes",
        // Descriptive keys that don't change what a rule does.
        "help", "creationDate", "modificationDate", "uid", "owner",
    ]

    private static func rule(_ value: [String: Any]) -> Rule {
        // A known key with a value of the wrong type, such as a number for
        // a name, would otherwise fall back to a wider default, so the rule
        // is skipped instead.
        var invalid: [String] = []
        func text(_ key: String) -> String? {
            guard let raw = value[key] else { return nil }
            guard let string = raw as? String else {
                invalid.append(key)
                return nil
            }
            return string
        }
        func textOrNumber(_ key: String) -> String? {
            guard let raw = value[key] else { return nil }
            if let string = raw as? String { return string.trimmingCharacters(in: .whitespaces) }
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                return number.stringValue
            }
            invalid.append(key)
            return nil
        }
        func names(_ key: String) -> [String] {
            let raw = value[key]
            if raw is String { return strings(raw) }
            if let list = raw as? [Any], list.allSatisfy({ $0 is String }) { return strings(raw) }
            invalid.append(key)
            return []
        }
        let remote: Remote
        if value["remote-hosts"] != nil {
            remote = .hosts(names("remote-hosts"))
        } else if value["remote-domains"] != nil {
            remote = .domains(names("remote-domains"))
        } else if value["remote-addresses"] != nil {
            remote = .addresses(names("remote-addresses").joined(separator: ","))
        } else if let named = text("remote"), named != "any" {
            remote = .named(named)
        } else {
            remote = .any
        }
        let remoteKeys = ["remote-hosts", "remote-domains", "remote-addresses", "remote"]
            .filter { value[$0] != nil }
        var unknown = value.keys.filter { !knownKeys.contains($0) }.sorted()
        // Only one destination key is allowed; more than one is ambiguous.
        if remoteKeys.count > 1 { unknown.append(contentsOf: remoteKeys.dropFirst()) }
        // An owner other than this account can't be matched the same way.
        if let owner = value["owner"] as? String, owner != "me" { unknown.append("owner") }
        let processText = text("process")
        let processValue = Self.process(processText)
        if processText != nil, processValue == nil { invalid.append("process") }
        let viaText = text("via")
        let viaValue = Self.process(viaText)
        if viaText != nil, viaValue == nil { invalid.append("via") }
        var disabled = false
        if let raw = value["disabled"] {
            if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
                disabled = number.boolValue
            } else {
                invalid.append("disabled")
            }
        }
        let action = text("action") ?? "ask"
        let direction = text("direction") ?? "outgoing"
        let priority = text("priority") ?? "regular"
        let ports = textOrNumber("ports") ?? "any"
        let transport = textOrNumber("protocol")?.lowercased() ?? "any"
        let notes = text("notes") ?? ""
        return Rule(
            process: processValue ?? .any,
            via: viaValue,
            action: action,
            remote: remote,
            direction: direction,
            priority: priority,
            disabled: disabled,
            ports: ports,
            transport: transport,
            notes: notes,
            unknownKeys: unknown + invalid
        )
    }

    private static func process(_ value: String?) -> Process? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value == "any" { return .any }
        if value.hasPrefix("identifier.") {
            let body = value.dropFirst("identifier.".count)
            let parts = body.split(separator: "/", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return .path(value) }
            return .codeID(team: String(parts[0]), identifier: String(parts[1]))
        }
        return .path(value)
    }

    /// A string or an array of strings; a string may hold several values
    /// separated by commas or spaces.
    private static func strings(_ value: Any?) -> [String] {
        let raw: [String]
        if let text = value as? String {
            raw = [text]
        } else if let list = value as? [Any] {
            raw = list.compactMap { $0 as? String }
        } else {
            raw = []
        }
        return raw.flatMap { $0.split(whereSeparator: { $0 == "," || $0.isWhitespace }) }
            .map(String.init)
    }
}
