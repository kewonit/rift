import AbyssCore
import Foundation

public enum RuleWorkspaceCopyDetails {
    public static let maximumUTF8Bytes = 128 * 1_024

    public static func text(
        for rule: Rule,
        context: RuleWorkspaceQueryContext? = nil
    ) -> String {
        var lines = [
            "Abyss rule details",
            "Rule ID: \(rule.id.uuidString.lowercased())",
            "Revision: \(rule.revision)",
            "Action: \(action(rule.action))",
        ]
        appendProcess(rule.process, to: &lines)
        lines.append(contentsOf: [
            "Destination: \(destination(rule.destination))",
            "Protocol: \(transport(rule.transportProtocol))",
            "Port: \(port(rule.port))",
            "Direction: \(direction(rule.direction))",
            "Owner: \(owner(rule.owner))",
        ])
        appendAssignment(
            label: "Profile",
            id: rule.profileID,
            name: rule.profileID.flatMap { context?.profileNames[$0] },
            empty: "All profiles",
            to: &lines
        )
        appendAssignment(
            label: "Group",
            id: rule.localGroupID,
            name: rule.localGroupID.flatMap { context?.localGroupNames[$0] },
            empty: "No group",
            to: &lines
        )
        lines.append(contentsOf: [
            "Priority: \(priority(rule.priority))",
            "Source: \(source(rule.source, context: context))",
            "Flags: \(flags(rule.flags))",
            "Enabled: \(rule.isEnabled ? "Yes" : "No")",
            "Review: \(rule.reviewState == .reviewed ? "Reviewed" : "Unreviewed")",
            "Expires: \(rule.expiresAt.map(timestamp) ?? "Never")",
            "Created: \(timestamp(rule.createdAt))",
            "Modified: \(timestamp(rule.modifiedAt))",
        ])
        if !rule.notes.isEmpty {
            lines.append("Note: \(safe(rule.notes, maximumScalars: PolicyLimits.maximumNotesScalars))")
        }
        let result = lines.joined(separator: "\n")
        guard result.utf8.count <= maximumUTF8Bytes else {
            return [
                "Abyss rule details",
                "Rule ID: \(rule.id.uuidString.lowercased())",
                "Details unavailable: the canonical text exceeds the copy limit.",
            ].joined(separator: "\n")
        }
        return result
    }

    private static func appendProcess(_ process: ProcessCondition, to lines: inout [String]) {
        switch process {
        case .anyProcess:
            lines.append("Application: Any application")
        case .exact(let identity):
            appendIdentity(identity, label: "Application", to: &lines)
        case .appViaHelper(let app, let helper):
            appendIdentity(app, label: "Application", to: &lines)
            appendIdentity(helper, label: "Helper", to: &lines)
        }
    }

    private static func appendIdentity(
        _ identity: ProcessIdentity,
        label: String,
        to lines: inout [String]
    ) {
        switch identity {
        case .applePlatform(let signed):
            appendSigned(signed, kind: "Apple platform", label: label, to: &lines)
        case .developerID(let signed):
            appendSigned(signed, kind: "Developer ID", label: label, to: &lines)
        case .appStore(let signed):
            appendSigned(signed, kind: "App Store", label: label, to: &lines)
        case .otherSigner(let hash, let identifier):
            lines.append("\(label) identity: Other signer")
            lines.append("\(label) signing identifier: \(safe(identifier))")
            lines.append("\(label) public-key SHA-256: \(hash.description)")
        case .adHoc(let hash):
            lines.append("\(label) identity: Ad hoc")
            lines.append("\(label) CDHash: \(hash.description)")
        case .unsigned(let path, let hash):
            lines.append("\(label) identity: Unsigned")
            lines.append("\(label) path: \(safe(path))")
            lines.append("\(label) file SHA-256: \(hash.description)")
        }
    }

    private static func appendSigned(
        _ identity: SignedCodeIdentity,
        kind: String,
        label: String,
        to lines: inout [String]
    ) {
        lines.append("\(label) identity: \(kind)")
        lines.append("\(label) signing identifier: \(safe(identity.signingIdentifier))")
        lines.append("\(label) team identifier: \(identity.teamIdentifier.map { safe($0) } ?? "None")")
    }

    private static func appendAssignment(
        label: String,
        id: UUID?,
        name: String?,
        empty: String,
        to lines: inout [String]
    ) {
        guard let id else {
            lines.append("\(label): \(empty)")
            return
        }
        lines.append("\(label): \(name.map { safe($0) } ?? "Unavailable")")
        lines.append("\(label) ID: \(id.uuidString.lowercased())")
    }

    private static func action(_ value: RuleAction) -> String {
        switch value {
        case .filter(.allow): "Allow"
        case .filter(.deny): "Deny"
        case .filter(.ask): "Ask"
        case .notification: "Notify"
        case .privacy: "Hide"
        }
    }

    private static func destination(_ value: DestinationCondition) -> String {
        switch value {
        case .ipSet(let values): values.map(\.description).joined(separator: ", ")
        case .exactHostnameSet(let values): values.map(\.ascii).joined(separator: ", ")
        case .domainSet(let values): values.map { "*." + $0.ascii }.joined(separator: ", ")
        case .endpointClass(let value): value.rawValue
        case .anyEndpoint: "Any destination"
        }
    }

    private static func transport(_ value: ProtocolCondition) -> String {
        switch value {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .anySupportedProtocol: "TCP or UDP"
        }
    }

    private static func port(_ value: PortRange?) -> String {
        guard let value else { return "Any port" }
        return value.lowerBound == value.upperBound
            ? String(value.lowerBound)
            : "\(value.lowerBound)-\(value.upperBound)"
    }

    private static func direction(_ value: DirectionCondition) -> String {
        switch value {
        case .incoming: "Incoming"
        case .outgoing: "Outgoing"
        case .bidirectional: "Both"
        }
    }

    private static func owner(_ value: OwnerCondition) -> String {
        switch value {
        case .authorizedUser: "Authorized user"
        case .specificUser(let uid): "User ID \(uid)"
        case .system: "System"
        }
    }

    private static func priority(_ value: RulePriority) -> String {
        switch value {
        case .elevatedUser: "User exception"
        case .blocklistDeny: "Blocklist deny"
        case .normal: "Normal"
        }
    }

    private static func source(
        _ value: RuleSource,
        context: RuleWorkspaceQueryContext?
    ) -> String {
        switch value {
        case .manual: "Manual"
        case .imported: "Imported"
        case .blocklist(let id):
            context?.blocklistNames[id].map { "Blocklist \(safe($0)) [\(id.uuidString.lowercased())]" }
                ?? "Blocklist [\(id.uuidString.lowercased())]"
        case .feature(let identifier): "Feature \(safe(identifier))"
        }
    }

    private static func flags(_ value: RuleFlags) -> String {
        var labels: [String] = []
        if value.contains(.protected) { labels.append("Protected") }
        if value.contains(.sourceManaged) { labels.append("Source managed") }
        return labels.isEmpty ? "None" : labels.joined(separator: ", ")
    }

    private static func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: value)
    }

    private static func safe(
        _ value: String,
        maximumScalars: Int = PolicyLimits.maximumDisplayScalars
    ) -> String {
        DisplaySanitizer.plainText(value, maximumScalars: maximumScalars)
    }
}
