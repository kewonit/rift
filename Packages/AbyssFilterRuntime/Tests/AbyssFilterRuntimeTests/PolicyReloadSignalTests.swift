import Foundation
import Testing
@testable import AbyssFilterRuntime

private final class ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    var count: Int {
        lock.withLock { value }
    }
}

@Test func policyReloadSignalNotifiesEveryInstalledObserver() throws {
    let signal = PolicyReloadSignal()
    let first = ReloadCounter()
    let second = ReloadCounter()
    let firstToken = try #require(signal.install { _ in first.increment() })
    _ = try #require(signal.install { _ in second.increment() })

    signal.publish(nil)
    #expect(first.count == 1)
    #expect(second.count == 1)

    signal.remove(firstToken)
    signal.publish(nil)
    #expect(first.count == 1)
    #expect(second.count == 2)
}

@Test func policyReloadSignalBoundsSubscribersAndReusesReleasedCapacity() throws {
    let signal = PolicyReloadSignal()
    let tokens = try (0..<PolicyReloadSignal.maximumObservers).map { _ in
        try #require(signal.install { _ in })
    }

    #expect(signal.install { _ in } == nil)
    signal.remove(tokens[0])
    _ = try #require(signal.install { _ in })
}
