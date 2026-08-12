import AbyssCore
import Foundation

public struct MonitorQueryState: Sendable, Hashable {
    public var search: String
    public var lens: MonitorLens
    public var decision: MonitorDecisionFilter
    public var direction: MonitorDirectionFilter
    public var time: MonitorTimeFilter
    public var timeAnchor: Date?
    public var selectedTimeRange: ClosedRange<Date>?
    public var sort: MonitorSort
    public var focusedLocationID: String?

    public init(
        search: String = "",
        lens: MonitorLens = .application,
        decision: MonitorDecisionFilter = .all,
        direction: MonitorDirectionFilter = .all,
        time: MonitorTimeFilter = .day,
        timeAnchor: Date? = nil,
        selectedTimeRange: ClosedRange<Date>? = nil,
        sort: MonitorSort = .recent,
        focusedLocationID: String? = nil
    ) {
        self.search = search
        self.lens = lens
        self.decision = decision
        self.direction = direction
        self.time = time
        self.timeAnchor = time == .all ? nil : timeAnchor
        self.selectedTimeRange = selectedTimeRange
        self.sort = sort
        self.focusedLocationID = focusedLocationID
    }

    public var isLiveTimeRange: Bool { timeAnchor == nil }
    public var canNavigateBackward: Bool { time.supportsNavigation }
    public var canNavigateForward: Bool { time.supportsNavigation && timeAnchor != nil }

    public func baseTimeWindow(
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MonitorTimeWindow? {
        time.window(now: now, anchor: timeAnchor, calendar: calendar)
    }

    public func effectiveTimeWindow(
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MonitorTimeWindow? {
        guard let base = baseTimeWindow(now: now, calendar: calendar) else { return nil }
        guard let selectedTimeRange else { return base }
        return base.intersecting(selectedTimeRange)
    }

    public mutating func selectTimeFilter(_ value: MonitorTimeFilter) {
        time = value
        if value == .all { timeAnchor = nil }
        selectedTimeRange = nil
    }

    public mutating func selectTimeRange(
        _ range: ClosedRange<Date>?,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard let range else {
            selectedTimeRange = nil
            return
        }
        guard let base = baseTimeWindow(now: now, calendar: calendar),
              let normalized = base.intersecting(range),
              let start = normalized.start, let end = normalized.end else {
            selectedTimeRange = nil
            return
        }
        selectedTimeRange = start...Date(
            timeIntervalSinceReferenceDate: end.timeIntervalSinceReferenceDate.nextDown
        )
    }

    public mutating func navigateTime(
        _ direction: MonitorTimeNavigation,
        now: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        guard time.supportsNavigation else { return }
        if direction == .next, timeAnchor == nil { return }
        let reference = timeAnchor ?? now
        guard let displayed = time.interval(containing: reference, calendar: calendar),
              let targetDate = time.date(
                byAdding: direction == .previous ? -1 : 1,
                to: displayed.start,
                calendar: calendar
              ),
              let target = time.interval(containing: targetDate, calendar: calendar),
              let current = time.interval(containing: now, calendar: calendar) else { return }
        timeAnchor = target.start >= current.start ? nil : target.start
        selectedTimeRange = nil
    }

    public mutating func showNow() {
        timeAnchor = nil
        selectedTimeRange = nil
    }

    public func apply(
        to rows: [MonitorEventRow],
        geography: [String: GeoResolution],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> [MonitorDisplayRow] {
        apply(
            to: rows,
            geography: geography,
            now: now,
            calendar: calendar,
            cancellationCheck: {}
        )
    }

    public func applyCancellable(
        to rows: [MonitorEventRow],
        geography: [String: GeoResolution],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) throws -> [MonitorDisplayRow] {
        try apply(
            to: rows,
            geography: geography,
            now: now,
            calendar: calendar,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    func apply(
        to rows: [MonitorEventRow],
        geography: [String: GeoResolution],
        now: Date,
        calendar: Calendar = .autoupdatingCurrent,
        cancellationCheck: () throws -> Void
    ) rethrows -> [MonitorDisplayRow] {
        guard let window = effectiveTimeWindow(now: now, calendar: calendar) else { return [] }
        let matching = try MonitorQuery.filter(
            rows,
            search: search,
            lens: lens,
            decision: decision,
            direction: direction,
            timeWindow: window,
            sort: sort,
            geography: geography,
            cancellationCheck: cancellationCheck
        )
        guard let focusedLocationID else { return matching }
        var focused: [MonitorDisplayRow] = []
        focused.reserveCapacity(matching.count)
        for (index, row) in matching.enumerated() {
            if index.isMultiple(of: 64) { try cancellationCheck() }
            if row.geography.location?.stableID == focusedLocationID { focused.append(row) }
        }
        try cancellationCheck()
        return focused
    }

    public mutating func clearExcludingFilters() {
        search = ""
        decision = .all
        direction = .all
        time = .all
        timeAnchor = nil
        selectedTimeRange = nil
        focusedLocationID = nil
    }
}
