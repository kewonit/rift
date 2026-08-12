import Testing
@testable import RiftControl

@Test func notificationLimiterSchedulesSummaryAfterBurstSilence() {
    var limiter = NotificationRateLimiter(capacity: 2, refillPeriod: 10, now: 100)
    let first = limiter.admit(at: 100)
    let second = limiter.admit(at: 100)
    let third = limiter.admit(at: 100)
    #expect(first)
    #expect(second)
    #expect(!third)
    #expect(limiter.suppressedCount == 1)
    let delay = limiter.summaryDelay(at: 100)
    let early = limiter.takeSummary(at: 109.9)
    let ready = limiter.takeSummary(at: 110)
    #expect(delay == 10)
    #expect(early == nil)
    #expect(ready == 1)
    #expect(limiter.suppressedCount == 0)
}

@Test func notificationLimiterIgnoresWallClockRollback() {
    var limiter = NotificationRateLimiter(capacity: 1, refillPeriod: 10, now: 100)
    let first = limiter.admit(at: 100)
    let rollback = limiter.admit(at: 90)
    let delay = limiter.summaryDelay(at: 90)
    let early = limiter.takeSummary(at: 109.9)
    let ready = limiter.takeSummary(at: 110)
    #expect(first)
    #expect(!rollback)
    #expect(delay == 10)
    #expect(early == nil)
    #expect(ready == 1)
}

@Test func notificationLimiterSaturatesSuppressionAccounting() {
    #expect(NotificationRateLimiter.saturatingAdd(.max - 1, 1) == .max)
    #expect(NotificationRateLimiter.saturatingAdd(.max - 1, 2) == .max)
    #expect(NotificationRateLimiter.saturatingAdd(.max, 1) == .max)
}
