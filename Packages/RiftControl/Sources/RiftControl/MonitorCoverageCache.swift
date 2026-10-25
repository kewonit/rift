import Foundation
import RiftCore
import RiftIPC

public actor MonitorCoverageCache {
    private var tuple: PolicyTuple?
    private var matcher: CompiledRuleMatcher?
    private var nextExpiry: Date?

    public init() {}

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
