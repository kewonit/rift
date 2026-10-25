import Foundation

public final class PolicyReloadSignal: @unchecked Sendable {
    public static let maximumObservers = 8

    private let lock = NSLock()
    private var observers: [UUID: @Sendable (RuntimePolicy?) -> Void] = [:]

    public init() {}

    @discardableResult
    public func install(
        _ observer: @escaping @Sendable (RuntimePolicy?) -> Void
    ) -> UUID? {
        lock.withLock {
            guard observers.count < Self.maximumObservers else { return nil }
            let token = UUID()
            observers[token] = observer
            return token
        }
    }

    public func remove(_ token: UUID) {
        lock.withLock { observers[token] = nil }
    }

    public func publish(_ policy: RuntimePolicy?) {
        let callbacks = lock.withLock { Array(observers.values) }
        callbacks.forEach { $0(policy) }
    }
}
