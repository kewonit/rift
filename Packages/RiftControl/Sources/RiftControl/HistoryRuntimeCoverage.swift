import Foundation
import GRDB

public enum HistoryRuntimeTransition: Sendable, Hashable {
    case firstObservation
    case sameRuntime
    case runtimeRestart(HistoryCoverageInterval)

    public var detectedRestart: Bool {
        if case .runtimeRestart = self { return true }
        return false
    }
}

enum HistoryRuntimeCoverageStore {
    static func recordSuccessfulDrain(
        runtimeInstanceID: UUID,
        at drainedAt: Date,
        historyEnabled: Bool,
        in database: Database
    ) throws -> HistoryRuntimeTransition {
        let drainedSeconds = drainedAt.timeIntervalSince1970
        guard drainedSeconds.isFinite,
              let row = try Row.fetchOne(
                database,
                sql: "SELECT last_runtime_instance_id, last_successful_drain_at FROM history_coverage_state WHERE singleton_id = 1"
              ) else {
            throw HistoryDatabaseError.integrityCheckFailed
        }
        let runtimeID = runtimeInstanceID.uuidString.lowercased()
        let previousRuntimeID: String? = row["last_runtime_instance_id"]
        let previousDrainSeconds: Double? = row["last_successful_drain_at"]
        let previousDrain = previousDrainSeconds.flatMap { $0.isFinite ? $0 : nil }
        let transition: HistoryRuntimeTransition
        if previousRuntimeID == nil {
            transition = .firstObservation
        } else if previousRuntimeID == runtimeID {
            transition = .sameRuntime
        } else {
            let start = previousDrainSeconds.flatMap {
                $0.isFinite ? Date(timeIntervalSince1970: $0) : nil
            } ?? drainedAt
            let interval = HistoryCoverageInterval(
                startedAt: start,
                endedAt: drainedAt,
                reason: .extensionRuntimeRestart
            )
            if historyEnabled {
                try HistoryCoverageStore.record(interval, in: database)
            }
            transition = .runtimeRestart(interval)
        }
        let storedDrainSeconds = previousRuntimeID == runtimeID
            ? max(previousDrain ?? drainedSeconds, drainedSeconds)
            : drainedSeconds
        try database.execute(
            sql: "UPDATE history_coverage_state SET last_runtime_instance_id = ?, last_successful_drain_at = ? WHERE singleton_id = 1",
            arguments: [runtimeID, storedDrainSeconds]
        )
        return transition
    }
}
