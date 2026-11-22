import Foundation

/// Notices a filter that says it's on but has gone quiet. The worst failures
/// of a firewall are silent: after some macOS updates a filter stays enabled
/// while it sees no traffic and applies no rules. A Mac with a working
/// network makes connections every few minutes, so a long silence while Rift
/// is listening is worth saying out loud.
public enum FilterLiveness {
    public static let silenceThreshold: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - lastFlowAt: when a connection last reached Rift.
    ///   - listeningSince: since when Rift has been receiving connections,
    ///     with the filter ready; nil when it isn't, such as with history off
    ///     and no activity view open.
    ///   - networkUpSince: since when the Mac has had a working network, or
    ///     nil when it hasn't.
    public static func isSilent(
        now: Date,
        lastFlowAt: Date?,
        listeningSince: Date?,
        networkUpSince: Date?
    ) -> Bool {
        guard let listeningSince, let networkUpSince else { return false }
        let evidence = max(lastFlowAt ?? .distantPast, listeningSince, networkUpSince)
        return now.timeIntervalSince(evidence) >= silenceThreshold
    }
}
