import Foundation

/// How long and how much connection history Rift keeps. A year and 200,000
/// connections are the most; a month and 50,000 stay the defaults. The Map,
/// the timeline and Review still read at most the newest
/// `HistoryLimits.maximumLoadedFlows`, so a longer history costs disk space,
/// not memory, and an export reads it one connection at a time.
public enum HistoryLimits {
    public static let retentionDays = 1...365
    public static let flowCount = 100...200_000
    public static let defaultRetentionDays = 30
    public static let defaultMaximumFlows = 50_000
    /// The most connections a view loads at once.
    public static let maximumLoadedFlows = 50_000

    static let dayChoices = [1, 3, 7, 14, 30, 60, 90, 180, 365]
    static let flowChoices = [1_000, 5_000, 10_000, 25_000, 50_000, 100_000, 150_000, 200_000]

    /// The choices Settings › History offers, with the current value kept
    /// even when it isn't one of them, so opening Settings changes nothing.
    public static func dayChoices(including current: Int) -> [Int] {
        choices(dayChoices, including: current, within: retentionDays)
    }

    public static func flowChoices(including current: Int) -> [Int] {
        choices(flowChoices, including: current, within: flowCount)
    }

    public static func daysLabel(_ days: Int) -> String {
        switch days {
        case 1: String(localized: "1 day", bundle: .module)
        case 7: String(localized: "1 week", bundle: .module)
        case 14: String(localized: "2 weeks", bundle: .module)
        case 30: String(localized: "30 days", bundle: .module)
        case 365: String(localized: "1 year", bundle: .module)
        default: String(localized: "\(days) days", bundle: .module)
        }
    }

    static func clampedDays(_ days: Int) -> Int { min(max(retentionDays.lowerBound, days), retentionDays.upperBound) }
    static func clampedFlows(_ flows: Int) -> Int { min(max(flowCount.lowerBound, flows), flowCount.upperBound) }

    private static func choices(_ values: [Int], including current: Int, within range: ClosedRange<Int>) -> [Int] {
        guard range.contains(current), !values.contains(current) else { return values }
        return (values + [current]).sorted()
    }
}
