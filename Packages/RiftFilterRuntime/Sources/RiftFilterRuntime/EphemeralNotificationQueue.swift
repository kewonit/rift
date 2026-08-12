import RiftIPC
import Foundation

public final class EphemeralNotificationQueue: @unchecked Sendable {
    private static let maximumCount = 256
    private static let maximumAge: TimeInterval = 30
    private let lock = NSLock()
    private var values: [EphemeralNotificationEvent] = []
    private var activitySignal: (@Sendable () -> Void)?

    public init() {}

    public func installActivitySignal(_ signal: @escaping @Sendable () -> Void) {
        lock.withLock { activitySignal = signal }
    }

    public func append(_ value: EphemeralNotificationEvent) {
        let signal = lock.withLock { () -> (@Sendable () -> Void)? in
            if values.count == Self.maximumCount { values.removeFirst() }
            values.append(value)
            return activitySignal
        }
        signal?()
    }

    public func drain(now: Date, maximumCount: Int = 64) -> [EphemeralNotificationEvent] {
        lock.withLock {
            values.removeAll { now.timeIntervalSince($0.occurredAt) > Self.maximumAge }
            let count = min(max(1, maximumCount), 64, values.count)
            let result = Array(values.prefix(count))
            values.removeFirst(count)
            return result
        }
    }
}
