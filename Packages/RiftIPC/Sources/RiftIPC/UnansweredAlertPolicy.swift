import RiftCore
import Foundation

public enum UnansweredAlertPolicyError: Error, Sendable, Equatable {
    case actionMustAllowOrDeny
    case waitOutOfRange(UInt16)
}

/// What the filter does with a connection whose alert nobody answers, and how
/// long it waits first. It travels in the compiled policy, so the filter
/// enforces it without Rift running.
///
/// A policy without one keeps the behaviour of every earlier build: 30
/// seconds for TCP, 8 for UDP, then Allow.
public struct UnansweredAlertPolicy: Sendable, Hashable, Codable {
    public static let legacyTCPWait: TimeInterval = 30
    public static let legacyUDPWait: TimeInterval = 8
    public static let minimumWaitSeconds: UInt16 = 5
    /// The longest a connection may wait for an answer. How long macOS keeps
    /// a paused flow alive hasn't been measured, so this stays inside the
    /// connect timeouts apps commonly use instead of promising to wait until
    /// answered.
    public static let maximumWaitSeconds: UInt16 = 120

    /// `.allow` or `.deny`.
    public let action: FilterAction
    public let waitSeconds: UInt16

    public init(action: FilterAction, waitSeconds: UInt16) throws {
        guard action == .allow || action == .deny else {
            throw UnansweredAlertPolicyError.actionMustAllowOrDeny
        }
        guard (Self.minimumWaitSeconds...Self.maximumWaitSeconds).contains(waitSeconds) else {
            throw UnansweredAlertPolicyError.waitOutOfRange(waitSeconds)
        }
        self.action = action
        self.waitSeconds = waitSeconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                action: try values.decode(FilterAction.self, forKey: .action),
                waitSeconds: try values.decode(UInt16.self, forKey: .waitSeconds)
            )
        } catch let error as UnansweredAlertPolicyError {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid unanswered alert policy: \(error)",
                underlyingError: error
            ))
        }
    }

    /// How long a connection of this kind waits for an answer. UDP never
    /// waits longer than it always has: its senders retry or give up within
    /// seconds, so a longer hold would only delay the outcome.
    public func wait(for transport: TransportProtocol) -> TimeInterval {
        min(TimeInterval(waitSeconds), Self.longestHold(for: transport))
    }

    /// The longest the filter holds one connection, counting the time spent
    /// working out which app it belongs to before the alert could be shown.
    public static func longestHold(for transport: TransportProtocol) -> TimeInterval {
        transport == .udp ? legacyUDPWait : TimeInterval(maximumWaitSeconds)
    }

    /// When a connection stops waiting for an answer. Without a policy the
    /// wait is counted from when the connection was first seen, as it always
    /// was. With one, the chosen wait starts when the alert is asked for, so
    /// a slow identity check doesn't use it up, and the whole hold still
    /// ends within `longestHold`.
    public static func deadline(
        for transport: TransportProtocol,
        observedAt: Date,
        askedAt: Date,
        policy: UnansweredAlertPolicy?
    ) -> Date {
        guard let policy else {
            return observedAt.addingTimeInterval(transport == .udp ? legacyUDPWait : legacyTCPWait)
        }
        return min(
            max(askedAt, observedAt).addingTimeInterval(policy.wait(for: transport)),
            observedAt.addingTimeInterval(longestHold(for: transport))
        )
    }

    /// What happens to a connection nobody answered. Without a policy it's
    /// allowed, as it always was.
    public static func action(for policy: UnansweredAlertPolicy?) -> FilterAction {
        policy?.action ?? .allow
    }

    private enum CodingKeys: String, CodingKey {
        case action, waitSeconds
    }
}
