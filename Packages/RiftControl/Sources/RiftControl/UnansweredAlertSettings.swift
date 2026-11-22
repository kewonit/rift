import RiftCore
import RiftIPC
import Foundation

/// Settings › Alerts: how long an alert waits for an answer, and what happens
/// to the connection when there isn't one.
public struct UnansweredAlertSettings: Sendable, Hashable {
    public static let blocksKey = "alertsBlockUnanswered"
    public static let waitSecondsKey = "alertsAnswerWaitSeconds"
    public static let defaultWaitSeconds = 30
    /// The waits Settings offers. The longest is the filter's own cap.
    public static let waitChoices = [15, 30, 60, Int(UnansweredAlertPolicy.maximumWaitSeconds)]

    public let blocks: Bool
    public let waitSeconds: Int

    /// `storedWaitSeconds` is what Settings saved. Anything that isn't one of
    /// the choices, including the 0 of a setting never touched, is the
    /// default.
    public init(blocks: Bool, storedWaitSeconds: Int) {
        self.blocks = blocks
        self.waitSeconds = Self.waitChoices.contains(storedWaitSeconds)
            ? storedWaitSeconds : Self.defaultWaitSeconds
    }

    /// The policy the filter should hold. Nil for the defaults, so a policy
    /// that changes nothing keeps the bytes every filter accepts, and nil
    /// when the filter is too old to enforce one.
    public func filterPolicy(filterSupportsIt: Bool) -> UnansweredAlertPolicy? {
        guard filterSupportsIt, blocks || waitSeconds != Self.defaultWaitSeconds else { return nil }
        return try? UnansweredAlertPolicy(
            action: blocks ? .deny : .allow,
            waitSeconds: UInt16(waitSeconds)
        )
    }

    public static func waitTitle(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        return seconds == 60 ? "1 minute" : "\(seconds / 60) minutes"
    }

    /// What Settings says under the choices.
    public func explanation(filterEnforces: Bool) -> String {
        guard blocks else {
            return "If you don’t answer in time, Rift lets the connection through."
        }
        return filterEnforces
            ? "If you don’t answer in time, the connection is blocked. That includes connections that would need an answer while Rift isn’t open. Before you log in, or while another account is using this Mac, they’re still allowed."
            : "If you don’t answer in time, Rift blocks the connection. When Rift isn’t open, or before you log in, connections nobody can answer are still allowed."
    }
}

/// What happens to one waiting connection if nobody answers, and what makes
/// it happen.
public enum UnansweredAlertOutcome: Sendable, Equatable {
    case allowedByFilter
    case blockedByFilter
    /// The filter would allow the connection, because it's older than
    /// protocol 1.4 or hasn't taken the setting yet, so Rift answers Block
    /// just before the filter's deadline. This only works while Rift is open.
    case blockedByApp

    /// How long before the filter's deadline Rift answers Block.
    public static let appBlockLead: TimeInterval = 1.5

    public init(prompt: PromptRequest, blocksUnanswered: Bool) {
        if prompt.unansweredAction == .deny {
            self = .blockedByFilter
        } else {
            self = blocksUnanswered ? .blockedByApp : .allowedByFilter
        }
    }

    public var blocks: Bool { self != .allowedByFilter }

    /// The last moment an answer still counts.
    public func answerDeadline(for prompt: PromptRequest) -> Date {
        self == .blockedByApp
            ? prompt.deadline.addingTimeInterval(-Self.appBlockLead) : prompt.deadline
    }

    public func countdownLabel(for prompt: PromptRequest, now: Date) -> String {
        let end = answerDeadline(for: prompt)
        let remaining = max(0, Int(end.timeIntervalSince(now).rounded(.up)))
        guard remaining > 0 else {
            return blocks ? "Not answered — connection blocked" : "Timed out — connection allowed"
        }
        let verb = blocks ? "Blocking" : "Allowing"
        let minutes = remaining / 60
        let seconds = remaining % 60
        return minutes > 0
            ? "\(verb) in \(minutes):\(String(format: "%02d", seconds))"
            : "\(verb) in \(seconds)s"
    }
}
