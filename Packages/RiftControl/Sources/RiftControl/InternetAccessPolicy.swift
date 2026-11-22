import Foundation
import RiftCore

public enum InternetAccessPolicyError: Error, Sendable, Equatable {
    case tooLarge
    case unreadable
    case missingDescription
}

/// What a developer says their app connects to and why, from the Internet
/// Access Policy file the app ships in its own bundle. The format is
/// published for developers, and Rift reads it from disk only, so explaining
/// a connection never sends anything anywhere.
///
/// The words are the developer's, not Rift's. They're shown only for an app
/// whose signature covers the file, and they're kept short and plain.
public struct InternetAccessPolicy: Sendable, Hashable {
    public static let fileNames = ["InternetAccessPolicy.plist", "InternetAccessPolicy.json"]
    public static let stringsFileName = "InternetAccessPolicy.strings"
    public static let maximumBytes = 256 * 1_024
    public static let maximumConnections = 256
    public static let maximumHostsPerConnection = 64
    public static let maximumServices = 16
    public static let maximumTextScalars = 600

    public struct Service: Sendable, Hashable {
        public let name: String
        public let purpose: String
    }

    public enum NetworkProtocol: String, Sendable, Hashable {
        case tcp, udp, icmp
    }

    public struct Connection: Sendable, Hashable {
        public let hosts: [InternetAccessPolicyHost]
        /// Empty for any port.
        public let ports: [ClosedRange<UInt16>]
        /// Nil for any protocol.
        public let networkProtocol: NetworkProtocol?
        public let isIncoming: Bool
        public let isEssential: Bool
        public let purpose: String
        public let denyConsequences: String?
        public let services: [Service]
    }

    public let applicationDescription: String
    public let developerName: String?
    public let connections: [Connection]

    /// Reads a policy file in property list or JSON form.
    /// - Parameters:
    ///   - strings: the app's translations for the person's language, from
    ///     `InternetAccessPolicy.strings`. A text that names one of its keys
    ///     is replaced by the translation.
    ///   - appName: stands in for `%APPNAME%`.
    public static func decode(
        _ data: Data,
        strings: [String: String] = [:],
        appName: String? = nil
    ) throws -> InternetAccessPolicy {
        guard data.count <= maximumBytes else { throw InternetAccessPolicyError.tooLarge }
        guard let root = propertyList(data) as? [String: Any] else { throw InternetAccessPolicyError.unreadable }
        func text(_ value: Any?) -> String? {
            guard let raw = value as? String else { return nil }
            let localized = strings[raw] ?? raw
            let named = appName.map { localized.replacingOccurrences(of: "%APPNAME%", with: $0) } ?? localized
            let cleaned = plainText(named)
            return cleaned.isEmpty ? nil : cleaned
        }
        guard let description = text(root["ApplicationDescription"]) else {
            throw InternetAccessPolicyError.missingDescription
        }
        let rawConnections = (root["Connections"] as? [Any] ?? []).prefix(maximumConnections)
        let connections = rawConnections.compactMap { value -> Connection? in
            guard let entry = value as? [String: Any],
                  let hostText = entry["Host"] as? String,
                  let purpose = text(entry["Purpose"]) else { return nil }
            let hosts = hostText.split(separator: ",").prefix(maximumHostsPerConnection)
                .map { InternetAccessPolicyHost($0.trimmingCharacters(in: .whitespaces)) }
            guard !hosts.isEmpty, let ports = portRanges(entry["Port"]) else { return nil }
            var networkProtocol: NetworkProtocol?
            if let raw = entry["NetworkProtocol"] {
                // An unknown protocol can't be matched, rather than matching any.
                guard let value = (raw as? String)?.lowercased(),
                      let known = NetworkProtocol(rawValue: value) else { return nil }
                networkProtocol = known
            }
            let services = (entry["Services"] as? [Any] ?? []).prefix(maximumServices).compactMap { value -> Service? in
                guard let service = value as? [String: Any],
                      let name = text(service["Name"]), let purpose = text(service["Purpose"]) else { return nil }
                return Service(name: name, purpose: purpose)
            }
            return Connection(
                hosts: hosts,
                ports: ports,
                networkProtocol: networkProtocol,
                isIncoming: flag(entry["IsIncoming"]),
                isEssential: (entry["Relevance"] as? String)?.lowercased() == "essential",
                purpose: purpose,
                denyConsequences: text(entry["DenyConsequences"]),
                services: services
            )
        }
        return InternetAccessPolicy(
            applicationDescription: description,
            developerName: text(root["DeveloperName"]),
            connections: connections
        )
    }

    /// The translations in an `InternetAccessPolicy.strings` file.
    public static func strings(_ data: Data) -> [String: String] {
        guard data.count <= maximumBytes,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return [:]
        }
        return values.compactMapValues { $0 as? String }
    }

    /// JSON when the file reads as JSON, otherwise a property list in any of
    /// its forms. An old-style property list also starts with a brace, so
    /// JSON that doesn't parse gets a second try as one.
    private static func propertyList(_ data: Data) -> Any? {
        let first = data.first(where: { !" \t\r\n".utf8.contains($0) })
        if first == UInt8(ascii: "{"), let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func flag(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let text = (value as? String)?.lowercased() { return text == "yes" || text == "true" }
        return false
    }

    /// `20-30, 80, 443`, or nil when the text can't be read, so the
    /// description isn't stretched to every port.
    static func portRanges(_ value: Any?) -> [ClosedRange<UInt16>]? {
        guard let value else { return [] }
        let text: String
        if let string = value as? String {
            text = string
        } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            text = number.stringValue
        } else {
            return nil
        }
        var ranges: [ClosedRange<UInt16>] = []
        for part in text.split(separator: ",").prefix(64) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count), let lower = UInt16(bounds[0]),
                  let upper = UInt16(bounds.count == 2 ? bounds[1] : bounds[0]), lower <= upper else { return nil }
            ranges.append(lower...upper)
        }
        guard !ranges.isEmpty else { return nil }
        return ranges == [0...65_535] ? [] : ranges
    }

    /// The developer's text as plain words: a Markdown link keeps its label
    /// and loses its address, since the alert is no place for a link that
    /// looks like one of Rift's own controls. Line breaks become spaces.
    static func plainText(_ value: String) -> String {
        var output = ""
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "[") {
            output += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "]"),
               rest.index(after: close) < rest.endIndex, rest[rest.index(after: close)] == "(",
               let end = rest[close...].firstIndex(of: ")") {
                output += rest[afterOpen..<close]
                rest = rest[rest.index(after: end)...]
            } else {
                output += "["
                rest = rest[afterOpen...]
            }
        }
        output += rest
        let spaced = String(String.UnicodeScalarView(output.unicodeScalars.map { scalar in
            CharacterSet.newlines.contains(scalar) || scalar == "\t" ? " " : scalar
        }))
        let words = spaced.withoutControlCharacters.split(separator: " ", omittingEmptySubsequences: true)
        return String(words.joined(separator: " ").unicodeScalars.prefix(maximumTextScalars))
    }
}
