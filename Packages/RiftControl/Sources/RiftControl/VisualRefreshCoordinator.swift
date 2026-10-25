import Foundation

/// Event-driven visual refreshes. There is no timer while the view is idle or hidden.
@MainActor
public final class VisualRefreshCoordinator {
    private let interval: Duration
    private var visible = false
    private var pending = false
    private var immediate = false
    private var operation: (@MainActor () async -> Void)?
    private var runner: Task<Void, Never>?
    private var delay: Task<Void, Error>?
    private var completedAt: ContinuousClock.Instant?

    public init(interval: Duration = .seconds(1)) {
        self.interval = interval
    }

    public func setVisible(_ visible: Bool) {
        guard self.visible != visible else { return }
        self.visible = visible
        pending = true
        immediate = true
        if visible { startIfNeeded() }
        else { runner?.cancel(); delay?.cancel() }
    }

    public func request(immediate: Bool = false, operation: @escaping @MainActor () async -> Void) {
        self.operation = operation
        pending = true
        self.immediate = self.immediate || immediate
        if immediate { delay?.cancel() }
        startIfNeeded()
    }

    public func stop() {
        visible = false
        pending = false
        operation = nil
        runner?.cancel()
        delay?.cancel()
    }

    private func startIfNeeded() {
        guard visible, pending, operation != nil, runner == nil else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            defer {
                runner = nil
                delay = nil
                startIfNeeded()
            }
            while visible, pending, !Task.isCancelled {
                if !immediate, let completedAt {
                    let remaining = interval - completedAt.duration(to: .now)
                    if remaining > .zero {
                        let sleeper = Task { try await Task.sleep(for: remaining) }
                        delay = sleeper
                        _ = try? await sleeper.value
                        delay = nil
                    }
                }
                guard visible, !Task.isCancelled, let operation else { break }
                pending = false
                immediate = false
                await operation()
                completedAt = .now
            }
        }
    }
}
