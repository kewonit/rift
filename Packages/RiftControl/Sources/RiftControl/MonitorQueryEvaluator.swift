import Foundation

public struct MonitorQueryEvaluation: Sendable, Hashable {
    public let displayed: [MonitorDisplayRow]
    public let summary: MonitorSummarySnapshot

    public init(
        displayed: [MonitorDisplayRow],
        summary: MonitorSummarySnapshot
    ) {
        self.displayed = displayed
        self.summary = summary
    }
}

public struct MonitorQueryRequestID: Sendable, Hashable {
    private let value: UUID

    public init(value: UUID = UUID()) {
        self.value = value
    }
}

public enum MonitorQueryPublication {
    public static func permits(
        _ request: MonitorQueryRequestID,
        active: MonitorQueryRequestID,
        taskIsCancelled: Bool
    ) -> Bool {
        !taskIsCancelled && request == active
    }
}

public enum MonitorQueryEvaluator {
    public static func evaluate(
        rows: [MonitorEventRow],
        state: MonitorQueryState,
        now: Date,
        queryComplete: Bool,
        coverage: HistoryCoverageSnapshot
    ) async throws -> MonitorQueryEvaluation {
        try Task.checkCancellation()
        return try await MonitorQueryWorker.run {
            try evaluate(
                rows: rows,
                state: state,
                now: now,
                queryComplete: queryComplete,
                coverage: coverage,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }
    }

    static func evaluate(
        rows: [MonitorEventRow],
        state: MonitorQueryState,
        now: Date,
        queryComplete: Bool,
        coverage: HistoryCoverageSnapshot,
        cancellationCheck: () throws -> Void
    ) rethrows -> MonitorQueryEvaluation {
        try cancellationCheck()
        let filtered = try state.apply(
            to: rows,
            now: now,
            cancellationCheck: cancellationCheck
        )
        try cancellationCheck()
        let summary = MonitorSummaryBuilder.build(
            from: filtered,
            queryComplete: queryComplete,
            rangeCoverage: state.effectiveTimeWindow(now: now).map {
                coverage.coverage(for: $0, now: now)
            } ?? .gap
        )
        try cancellationCheck()
        return MonitorQueryEvaluation(
            displayed: filtered,
            summary: summary
        )
    }
}

public enum MonitorQueryWorker {
    public static func run<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
