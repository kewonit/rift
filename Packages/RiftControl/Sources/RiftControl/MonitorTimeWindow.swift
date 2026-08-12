import Foundation

public struct MonitorTimeWindow: Sendable, Hashable {
    public let start: Date?
    public let end: Date?

    public init?(start: Date?, end: Date?) {
        guard start.map(Self.isFinite) ?? true,
              end.map(Self.isFinite) ?? true else { return nil }
        if let start, let end, start >= end { return nil }
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool {
        guard Self.isFinite(date),
              start.map({ date >= $0 }) ?? true,
              end.map({ date < $0 }) ?? true else { return false }
        return true
    }

    public func intersecting(_ range: ClosedRange<Date>) -> MonitorTimeWindow? {
        guard Self.isFinite(range.lowerBound), Self.isFinite(range.upperBound),
              range.lowerBound < range.upperBound else { return nil }
        let lower = max(start ?? range.lowerBound, range.lowerBound)
        let selectedEnd = Self.exclusiveEnd(after: range.upperBound)
        let upper = min(end ?? selectedEnd, selectedEnd)
        return MonitorTimeWindow(start: lower, end: upper)
    }

    public func resolvedBounds(defaultStart: Date, defaultEnd: Date) -> (start: Date, end: Date)? {
        guard Self.isFinite(defaultStart), Self.isFinite(defaultEnd) else { return nil }
        let lower = start ?? defaultStart
        let upper = end ?? defaultEnd
        guard lower < upper else { return nil }
        return (lower, upper)
    }

    static func exclusiveEnd(after date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: date.timeIntervalSinceReferenceDate.nextUp)
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }
}

public enum MonitorTimeNavigation: Sendable, Equatable {
    case previous
    case next
}

extension MonitorTimeFilter {
    public var supportsNavigation: Bool { self != .all }

    public var decisionBucketWidth: TimeInterval {
        switch self {
        case .hour: 300
        case .day: 3_600
        case .week: 21_600
        case .month, .all: 86_400
        }
    }

    public func window(
        now: Date,
        anchor: Date? = nil,
        calendar: Calendar = .autoupdatingCurrent
    ) -> MonitorTimeWindow? {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              anchor.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { return nil }
        guard let component = calendarComponent else {
            return MonitorTimeWindow(start: nil, end: nil)
        }
        let reference = anchor ?? now
        guard let interval = calendar.dateInterval(of: component, for: reference) else {
            return nil
        }
        let end = anchor == nil ? MonitorTimeWindow.exclusiveEnd(after: now) : interval.end
        return MonitorTimeWindow(start: interval.start, end: end)
    }

    func interval(
        containing date: Date,
        calendar: Calendar
    ) -> DateInterval? {
        calendarComponent.flatMap { calendar.dateInterval(of: $0, for: date) }
    }

    func date(
        byAdding value: Int,
        to date: Date,
        calendar: Calendar
    ) -> Date? {
        guard let component = calendarComponent else { return nil }
        return calendar.date(byAdding: component, value: value, to: date)
    }

    private var calendarComponent: Calendar.Component? {
        switch self {
        case .all: nil
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }
}

public enum DecisionBucketGrid {
    public static func bucketStart(
        for date: Date,
        anchor: Date?,
        width: TimeInterval
    ) -> Date? {
        let seconds = date.timeIntervalSince1970
        let origin = anchor?.timeIntervalSince1970 ?? 0
        guard seconds.isFinite, origin.isFinite, width.isFinite, width >= 60 else { return nil }
        let offset = seconds - origin
        guard offset.isFinite else { return nil }
        let bucket = origin + floor(offset / width) * width
        guard bucket.isFinite else { return nil }
        return Date(timeIntervalSince1970: bucket)
    }
}
