import AbyssCore
import AbyssIPC
import Foundation

public struct MonitorSearchQuery: Sendable, Hashable {
    public static let maximumInputScalars = 2_048
    public static let maximumTokens = 32
    public static let maximumTokenScalars = 256

    public let isRejected: Bool
    public var tokenCount: Int { terms.count }

    private let terms: [Term]

    public init(_ input: String) {
        guard let lexemes = Self.lex(input) else {
            terms = []
            isRejected = true
            return
        }
        terms = lexemes.map(Self.term)
        isRejected = false
    }

    public func matches(_ row: MonitorEventRow, geography: GeoResolution) -> Bool {
        guard !isRejected else { return false }
        let document = Document(row: row, geography: geography)
        return terms.allSatisfy { term in
            switch term {
            case .unqualified(let value):
                document.unqualified.contains { $0.contains(value) }
            case .text(.application, let value):
                document.application.contains(value)
            case .text(.process, let value):
                document.process?.contains(value) == true
            case .host(let value):
                document.host == value
            case .ip(let value):
                document.ip == value
            case .port(let value):
                document.port == value
            case .decision(let value):
                document.decision == value
            case .direction(let value):
                document.direction == value
            }
        }
    }

    private enum TextField: Sendable, Hashable {
        case application
        case process
    }

    private enum Decision: Sendable, Hashable {
        case allowed
        case denied
        case unresolved
    }

    private enum Term: Sendable, Hashable {
        case unqualified(String)
        case text(TextField, String)
        case host(String)
        case ip(IPAddress)
        case port(UInt16)
        case decision(Decision)
        case direction(TrafficDirection)
    }

    private struct Lexeme {
        let value: String
    }

    private struct Document {
        let application: String
        let process: String?
        let host: String?
        let ip: IPAddress?
        let port: UInt16?
        let decision: Decision
        let direction: TrafficDirection
        let unqualified: [String]

        init(row: MonitorEventRow, geography: GeoResolution) {
            let flow = row.event.flow
            let applicationIdentity = flow.sourceAppIdentity ?? flow.sourceProcessIdentity
            application = normalizedMonitorSearchText(MonitorQuery.identityLabel(applicationIdentity))
            process = flow.sourceProcessIdentity.map {
                normalizedMonitorSearchText(MonitorQuery.identityLabel($0))
            }
            if flow.metadataConfidence.contains(.observedHostname),
               let observed = flow.observedHostname {
                host = normalizedMonitorSearchText(observed.ascii)
            } else {
                host = nil
            }
            let endpoint = flow.destinationEndpoint
            ip = endpoint?.address
            port = endpoint?.port
            decision = row.event.reason == .concreteDecision
                ? (row.event.action == .allow ? .allowed : .denied)
                : .unresolved
            direction = flow.direction

            let protocolValue: String = switch flow.transportProtocol {
            case .tcp: "tcp"
            case .udp: "udp"
            case .unsupported(let number): "protocol:\(number)"
            }
            let decisionValue: String = switch decision {
            case .allowed: "allow allowed"
            case .denied: "deny denied"
            case .unresolved: "fallback unresolved"
            }
            unqualified = [
                MonitorQuery.applicationLabel(row),
                flow.sourceProcessIdentity.map { MonitorQuery.identityLabel($0) } ?? "",
                MonitorQuery.endpointLabel(row),
                MonitorQuery.hostnameLabel(row),
                endpoint?.address.description ?? "",
                endpoint?.port.map(String.init) ?? "",
                decisionValue,
                protocolValue,
                flow.direction.rawValue,
                row.event.reason.rawValue,
                geography.searchableText,
            ].map(normalizedMonitorSearchText)
        }
    }

    private static func term(_ lexeme: Lexeme) -> Term {
        let value = lexeme.value
        guard let separator = value.firstIndex(of: ":") else {
            return .unqualified(normalizedMonitorSearchText(value))
        }
        let field = normalizedMonitorSearchText(String(value[..<separator]))
        let rawValue = String(value[value.index(after: separator)...])
        guard !rawValue.isEmpty else {
            return .unqualified(normalizedMonitorSearchText(value))
        }
        switch field {
        case "app":
            return .text(.application, normalizedMonitorSearchText(rawValue))
        case "process":
            return .text(.process, normalizedMonitorSearchText(rawValue))
        case "host":
            let canonical = (try? DomainName(rawValue))?.ascii ?? rawValue
            return .host(normalizedMonitorSearchText(canonical))
        case "ip":
            guard let address = try? IPAddress(rawValue) else {
                return .unqualified(normalizedMonitorSearchText(value))
            }
            return .ip(address)
        case "port":
            guard let port = UInt16(rawValue), port > 0 else {
                return .unqualified(normalizedMonitorSearchText(value))
            }
            return .port(port)
        case "decision":
            switch normalizedMonitorSearchText(rawValue) {
            case "allow", "allowed": return .decision(.allowed)
            case "deny", "denied": return .decision(.denied)
            case "fallback", "unresolved": return .decision(.unresolved)
            default: return .unqualified(normalizedMonitorSearchText(value))
            }
        case "direction":
            guard let direction = TrafficDirection(
                rawValue: normalizedMonitorSearchText(rawValue)
            ) else {
                return .unqualified(normalizedMonitorSearchText(value))
            }
            return .direction(direction)
        default:
            return .unqualified(normalizedMonitorSearchText(value))
        }
    }

    private static func lex(_ input: String) -> [Lexeme]? {
        guard input.unicodeScalars.prefix(maximumInputScalars + 1).count
                <= maximumInputScalars else { return nil }
        let characters = Array(input)
        var result: [Lexeme] = []
        var index = 0
        while index < characters.count {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            guard index < characters.count else { break }
            let start = index
            var cooked = ""
            var inQuotes = false
            var closedQuote = false
            var malformed = false
            while index < characters.count {
                let character = characters[index]
                if character.isWhitespace, !inQuotes { break }
                if character == "\"" {
                    if inQuotes {
                        inQuotes = false
                        closedQuote = true
                    } else if cooked.isEmpty || cooked.last == ":" {
                        guard !closedQuote else {
                            malformed = true
                            cooked.append(character)
                            index += 1
                            continue
                        }
                        inQuotes = true
                    } else {
                        cooked.append(character)
                    }
                } else {
                    if closedQuote { malformed = true }
                    cooked.append(character)
                }
                index += 1
            }
            if inQuotes { malformed = true }
            let raw = String(characters[start..<index])
            let value = malformed || cooked.isEmpty ? raw : cooked
            guard value.unicodeScalars.prefix(maximumTokenScalars + 1).count
                    <= maximumTokenScalars else { return nil }
            result.append(Lexeme(value: value))
            guard result.count <= maximumTokens else { return nil }
        }
        return result
    }

}

private func normalizedMonitorSearchText(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
        .lowercased(with: Locale(identifier: "en_US_POSIX"))
}
