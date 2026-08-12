public struct ControlPlaneReconnectState: Sendable, Equatable {
    public static let initialDelaySeconds: UInt64 = 1
    public static let maximumDelaySeconds: UInt64 = 30

    public private(set) var isRunning = false
    public private(set) var nextDelaySeconds = Self.initialDelaySeconds

    public init() {}

    @discardableResult
    public mutating func beginIfNeeded() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    public mutating func delayAfterFailureSeconds() -> UInt64? {
        guard isRunning else { return nil }
        let delay = nextDelaySeconds
        nextDelaySeconds = min(Self.maximumDelaySeconds, delay * 2)
        return delay
    }

    public mutating func finishAndReset() {
        isRunning = false
        nextDelaySeconds = Self.initialDelaySeconds
    }
}
