import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftControl

@Test func monitorCalendarWindowsRespectDSTAndCurrentTime() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let springForward = try monitorDate(
        year: 2024, month: 3, day: 10, hour: 12, calendar: calendar
    )
    let later = try monitorDate(
        year: 2024, month: 3, day: 12, hour: 12, calendar: calendar
    )

    let historic = try #require(MonitorTimeFilter.day.window(
        now: later, anchor: springForward, calendar: calendar
    ))
    let start = try #require(historic.start)
    let end = try #require(historic.end)
    #expect(end.timeIntervalSince(start) == 23 * 3_600)
    #expect(calendar.component(.hour, from: start) == 0)
    #expect(calendar.component(.hour, from: end) == 0)

    let live = try #require(MonitorTimeFilter.day.window(
        now: springForward, calendar: calendar
    ))
    #expect(live.start == start)
    #expect(try #require(live.end) > springForward)
    #expect(try #require(live.end).timeIntervalSince(springForward) < 0.001)
}

@Test func monitorWeekWindowHonorsTheCalendarFirstWeekday() throws {
    var sunday = Calendar(identifier: .gregorian)
    sunday.locale = Locale(identifier: "en_US_POSIX")
    sunday.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    sunday.firstWeekday = 1
    sunday.minimumDaysInFirstWeek = 1
    var monday = sunday
    monday.firstWeekday = 2
    let reference = try monitorDate(
        year: 2026, month: 8, day: 12, hour: 12, calendar: sunday
    )

    let sundayWindow = try #require(MonitorTimeFilter.week.window(
        now: reference, anchor: reference, calendar: sunday
    ))
    let mondayWindow = try #require(MonitorTimeFilter.week.window(
        now: reference, anchor: reference, calendar: monday
    ))
    #expect(sunday.component(.weekday, from: try #require(sundayWindow.start)) == 1)
    #expect(monday.component(.weekday, from: try #require(mondayWindow.start)) == 2)
    #expect(sundayWindow.start != mondayWindow.start)
}

@Test func historicNavigationIsStableAndReturnsToNow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try monitorDate(year: 2026, month: 8, day: 12, hour: 15, calendar: calendar)
    var query = MonitorQueryState(time: .day)

    query.navigateTime(.previous, now: now, calendar: calendar)
    let first = try #require(query.baseTimeWindow(now: now, calendar: calendar))
    #expect(!query.isLiveTimeRange)
    #expect(try #require(first.end) <= now)
    let clockRolledBack = now.addingTimeInterval(-3_600)
    #expect(query.baseTimeWindow(now: clockRolledBack, calendar: calendar) == first)

    let firstStart = try #require(first.start)
    let firstEnd = try #require(first.end)
    query.selectTimeRange(
        firstStart...firstEnd.addingTimeInterval(-1),
        now: now,
        calendar: calendar
    )
    #expect(query.selectedTimeRange != nil)
    query.navigateTime(.next, now: now, calendar: calendar)
    #expect(query.isLiveTimeRange)
    #expect(query.selectedTimeRange == nil)
}

@Test func chartSelectionFiltersTheSharedMonitorQueryAndClampsToItsWindow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = try monitorDate(year: 2026, month: 8, day: 12, hour: 15, calendar: calendar)
    let ten = try monitorDate(year: 2026, month: 8, day: 12, hour: 10, calendar: calendar)
    let noon = try monitorDate(year: 2026, month: 8, day: 12, hour: 12, calendar: calendar)
    let fourteen = try monitorDate(
        year: 2026, month: 8, day: 12, hour: 14, calendar: calendar
    )
    let rows = try [ten, noon, fourteen].enumerated().map {
        try monitorTimeRow(sequence: UInt64($0.offset + 1), at: $0.element)
    }
    var query = MonitorQueryState(time: .day)
    query.selectTimeRange(
        ten.addingTimeInterval(3_600)...noon.addingTimeInterval(3_600),
        now: now,
        calendar: calendar
    )
    #expect(query.apply(to: rows, geography: [:], now: now, calendar: calendar).map(\.id)
        == [rows[1].id])

    query.selectTimeRange(
        now.addingTimeInterval(3_600)...now.addingTimeInterval(7_200),
        now: now,
        calendar: calendar
    )
    #expect(query.selectedTimeRange == nil)
}

@Test func decisionBucketsAnchorToTheDisplayedRange() throws {
    let anchor = Date(timeIntervalSince1970: 1_000)
    let event = anchor.addingTimeInterval(719)
    let bucket = try #require(DecisionBucketGrid.bucketStart(
        for: event, anchor: anchor, width: 300
    ))
    #expect(bucket == anchor.addingTimeInterval(600))
    #expect(DecisionBucketGrid.bucketStart(for: event, anchor: anchor, width: 59) == nil)
    #expect(DecisionBucketGrid.bucketStart(
        for: event, anchor: Date(timeIntervalSinceReferenceDate: .infinity), width: 300
    ) == nil)
}

@Test func selectedRangeCoverageIsIndependentOfReturnedRows() throws {
    let start = Date(timeIntervalSince1970: 10_000)
    let snapshot = HistoryCoverageSnapshot(
        recordingSince: start,
        isRecording: true,
        intervals: [HistoryCoverageInterval(
            startedAt: start.addingTimeInterval(3_600),
            endedAt: start.addingTimeInterval(7_200),
            reason: .appWriteFailure
        )]
    )
    let affected = try #require(MonitorTimeWindow(
        start: start.addingTimeInterval(4_000),
        end: start.addingTimeInterval(5_000)
    ))
    let clear = try #require(MonitorTimeWindow(
        start: start.addingTimeInterval(100),
        end: start.addingTimeInterval(200)
    ))
    #expect(snapshot.coverage(for: affected, now: start.addingTimeInterval(10_000)) == .partial)
    #expect(snapshot.coverage(for: clear, now: start.addingTimeInterval(10_000)) == .complete)
}

private func monitorDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    calendar: Calendar
) throws -> Date {
    try #require(calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour
    )))
}

private func monitorTimeRow(sequence: UInt64, at date: Date) throws -> MonitorEventRow {
    let endpoint = Endpoint(
        address: try IPAddress("203.0.113.10"),
        port: 443,
        hostname: nil,
        hostnameCoverage: .absent,
        classes: [],
        interfaceSnapshotGeneration: 0
    )
    let flow = FlowDescriptor(
        flowID: UUID(),
        observedAt: date,
        sourceAppIdentity: nil,
        sourceProcessIdentity: nil,
        owner: .user(uid: 501),
        direction: .outgoing,
        transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: endpoint,
        observedHostname: nil,
        metadataConfidence: [.endpoint]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(),
            sequence: sequence,
            occurredAt: date,
            flow: flow,
            action: .allow,
            reason: .concreteDecision,
            policy: nil
        ),
        coverage: .complete
    )
}
