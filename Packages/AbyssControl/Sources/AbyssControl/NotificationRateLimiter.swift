import Foundation

public struct NotificationRateLimiter: Sendable {
    private let capacity: Double
    private let refillPeriod: TimeInterval
    private var tokens: Double
    private var lastRefill: TimeInterval
    public private(set) var suppressedCount: UInt64 = 0

    public init(
        capacity: Int = 5,
        refillPeriod: TimeInterval = 12,
        now: TimeInterval = 0
    ) {
        let boundedCapacity = max(1, capacity)
        self.capacity = Double(boundedCapacity)
        self.refillPeriod = max(0.001, refillPeriod)
        self.tokens = Double(boundedCapacity)
        self.lastRefill = now
    }

    public mutating func admit(at now: TimeInterval) -> Bool {
        refill(at: now)
        guard tokens >= 1 else {
            suppressedCount = Self.saturatingAdd(suppressedCount, 1)
            return false
        }
        tokens -= 1
        return true
    }

    public mutating func summaryDelay(at now: TimeInterval) -> TimeInterval? {
        refill(at: now)
        guard suppressedCount > 0 else { return nil }
        return tokens >= 1 ? 0 : (1 - tokens) * refillPeriod
    }

    public mutating func takeSummary(at now: TimeInterval) -> UInt64? {
        refill(at: now)
        guard suppressedCount > 0, tokens >= 1 else { return nil }
        tokens -= 1
        defer { suppressedCount = 0 }
        return suppressedCount
    }

    public mutating func discardSummary() {
        suppressedCount = 0
    }

    static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        let (result, overflow) = value.addingReportingOverflow(increment)
        return overflow ? .max : result
    }

    private mutating func refill(at now: TimeInterval) {
        guard now > lastRefill else { return }
        tokens = min(capacity, tokens + (now - lastRefill) / refillPeriod)
        lastRefill = now
    }
}
