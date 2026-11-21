import Foundation
import RiftCore

/// Changes to make to several rules at once. Anything left nil stays as each
/// rule has it.
public struct RuleBulkEdit: Sendable, Equatable {
    public enum PortChange: Sendable, Equatable {
        case any
        case range(PortRange)
    }

    public var action: RuleAction?
    public var transport: ProtocolCondition?
    public var port: PortChange?
    public var note: String?

    public init(
        action: RuleAction? = nil,
        transport: ProtocolCondition? = nil,
        port: PortChange? = nil,
        note: String? = nil
    ) {
        self.action = action
        self.transport = transport
        self.port = port
        self.note = note
    }

    public var isEmpty: Bool {
        action == nil && transport == nil && port == nil && note == nil
    }

    /// The rule with these changes, checked like any edit. Rules that Rift
    /// manages can't be edited and throw.
    public func applied(to rule: Rule, now: Date) throws -> Rule {
        let port: PortRange? = switch self.port {
        case nil: rule.port
        case .any: nil
        case .range(let range): range
        }
        return try RuleMutation.edited(
            rule,
            action: action ?? rule.action,
            priority: rule.priority,
            process: rule.process,
            destination: rule.destination,
            transport: transport ?? rule.transportProtocol,
            port: port,
            direction: rule.direction,
            owner: rule.owner,
            profileID: rule.profileID,
            localGroupID: rule.localGroupID,
            expiresAt: rule.expiresAt,
            isEnabled: rule.isEnabled,
            reviewState: rule.reviewState,
            note: note ?? rule.notes,
            now: now
        )
    }

    /// The rules with these changes. Rules not in `ids`, and rules that Rift
    /// manages, are left alone. One rule that can't take the change stops
    /// the whole edit, so nothing is half done.
    public func applied(to rules: [Rule], ids: Set<UUID>, now: Date) throws -> [Rule] {
        try rules.map { rule in
            guard ids.contains(rule.id),
                  !rule.flags.contains(.protected),
                  !rule.flags.contains(.sourceManaged) else { return rule }
            return try applied(to: rule, now: now)
        }
    }
}
