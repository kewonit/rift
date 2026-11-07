import Foundation
import RiftCore
import RiftIPC

public actor MonitorCoverageCache {
    private var tuple: PolicyTuple?
    private var matcher: CompiledRuleMatcher?
    private var nextExpiry: Date?

    /// The rule snapshot the monitor last loaded. Rebuilding it reads and
    /// re-verifies the whole configuration, so the once-a-second activity
    /// refresh reuses it briefly; app-made changes invalidate it at once.
    private var cachedSnapshot: (value: RuleWorkspaceSnapshot, loadedAt: ContinuousClock.Instant)?
    public static let snapshotLifetime: Duration = .seconds(5)

    public init() {}

    public func snapshot(
        now: ContinuousClock.Instant = .now,
        load: @Sendable () async throws -> RuleWorkspaceSnapshot?
    ) async throws -> RuleWorkspaceSnapshot? {
        if let cachedSnapshot, cachedSnapshot.loadedAt.duration(to: now) < Self.snapshotLifetime {
            return cachedSnapshot.value
        }
        guard let value = try await load() else {
            cachedSnapshot = nil
            return nil
        }
        cachedSnapshot = (value, now)
        return value
    }

    public func invalidateSnapshot() {
        cachedSnapshot = nil
    }

    public func evaluate(
        _ rows: [MonitorEventRow],
        snapshot: RuleWorkspaceSnapshot,
        enforcementState: PolicyOutboxState,
        now: Date = Date()
    ) throws -> [String: MonitorRuleCoverage] {
        try Task.checkCancellation()
        if matcher == nil || tuple != snapshot.desiredTuple || nextExpiry.map({ $0 <= now }) == true {
            matcher = CompiledRuleMatcher(rules: snapshot.configuration.rules)
            tuple = snapshot.desiredTuple
            nextExpiry = snapshot.configuration.rules.compactMap(\.expiresAt).filter { $0 > now }.min()
        }
        guard let matcher else { return [:] }
        let result = MonitorCoverageEvaluator.evaluate(
            rows, configuration: snapshot.configuration, enforcementState: enforcementState,
            desiredTuple: snapshot.desiredTuple, now: now, matcher: matcher
        )
        try Task.checkCancellation()
        return result
    }
}
