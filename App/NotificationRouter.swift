import RiftControl
import RiftIPC
import Foundation
import UserNotifications

actor NotificationRouter {
    private let clock = ContinuousClock()
    private let clockOrigin: ContinuousClock.Instant
    private var limiter = NotificationRateLimiter()
    private var summaryTask: Task<Void, Never>?
    private(set) var deliveryFailureCount: UInt64 = 0

    init() {
        clockOrigin = ContinuousClock().now
    }

    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge])
    }

    func route(_ events: [RuntimeEvent]) async {
        guard notificationsEnabled else { cancelSummary(); return }
        for event in events where event.kind == .decision
            && !event.notificationRequested
            && (event.action == .deny || event.reason != .concreteDecision) {
            guard limiter.admit(at: monotonicTime) else { continue }
            let content = UNMutableNotificationContent()
            content.title = event.action == .deny ? "Rift denied a connection" : "Rift allowed a connection by default"
            if UserDefaults.standard.bool(forKey: "notificationSensitiveDetails"),
               let endpoint = event.flow.destinationEndpoint {
                let value = endpoint.hostname?.ascii ?? endpoint.address.description
                content.body = "Destination: \(value)"
            } else {
                content.body = "Open Rift to see the details."
            }
            await deliver(
                UNNotificationRequest(identifier: event.id, content: content, trigger: nil)
            )
        }
        scheduleSummaryIfNeeded()
    }

    func route(_ events: [EphemeralNotificationEvent]) async {
        guard notificationsEnabled else { cancelSummary(); return }
        for event in events {
            guard limiter.admit(at: monotonicTime) else { continue }
            let content = UNMutableNotificationContent()
            content.title = event.action == .deny
                ? "Rift denied a connection" : "Rift observed a connection"
            if UserDefaults.standard.bool(forKey: "notificationSensitiveDetails"),
               let endpoint = event.flow.destinationEndpoint {
                let value = endpoint.hostname?.ascii ?? endpoint.address.description
                content.body = "Destination: \(value)"
            } else {
                content.body = "A notification rule matched. Open Rift to see the details."
            }
            await deliver(
                UNNotificationRequest(
                    identifier: "rift-notify-\(event.id.uuidString.lowercased())",
                    content: content,
                    trigger: nil
                )
            )
        }
        scheduleSummaryIfNeeded()
    }

    func healthMessage() -> String? {
        deliveryFailureCount == 0 ? nil : "Some notifications couldn’t be shown."
    }

    private var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "notificationsEnabled")
    }

    private var monotonicTime: TimeInterval {
        let value = clockOrigin.duration(to: clock.now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1_000_000_000_000_000_000
    }

    private func scheduleSummaryIfNeeded() {
        guard summaryTask == nil, let delay = limiter.summaryDelay(at: monotonicTime) else { return }
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.deliverSummary()
        }
    }

    private func deliverSummary() async {
        summaryTask = nil
        guard notificationsEnabled else { limiter.discardSummary(); return }
        guard let count = limiter.takeSummary(at: monotonicTime) else {
            scheduleSummaryIfNeeded()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Rift connection summary"
        content.body = count == 1
            ? "1 more notification was combined into this summary."
            : "\(count) more notifications were combined into this summary."
        await deliver(UNNotificationRequest(
            identifier: "rift-summary-\(UUID().uuidString.lowercased())",
            content: content,
            trigger: nil
        ))
        scheduleSummaryIfNeeded()
    }

    private func deliver(_ request: UNNotificationRequest) async {
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            if deliveryFailureCount < .max { deliveryFailureCount += 1 }
        }
    }

    private func cancelSummary() {
        summaryTask?.cancel()
        summaryTask = nil
        limiter.discardSummary()
    }
}

private extension RuntimeEvent {
    var id: String { "rift-\(providerEpoch.uuidString)-\(sequence)" }
}
